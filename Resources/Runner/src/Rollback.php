<?php

declare(strict_types=1);

/*
 * Rollback mode (#13): a dry run of a PHP tab. Before the snippet runs, Runlet begins a
 * transaction on every database connection the booted driver lists in rollbackConnections():
 * Laravel's and Eloquent's connections (and, where the framework announces them, the ones the
 * snippet opens later), Doctrine DBAL connections, WordPress's $wpdb, and plain PDO. After the
 * snippet, Runlet always rolls them back: when it returns, throws, calls exit() or dd(), or
 * ends in a fatal error (Runner::finish()). When Stop kills PHP, the database discards the
 * open transaction once the connection closes.
 *
 * The run inspector reports every statement (Inspector::query() calls observe()), so Runlet
 * counts what each connection ran, and notices what a transaction can't undo: DDL and the
 * other statements MySQL and MariaDB commit implicitly, a COMMIT or ROLLBACK of the
 * application's own, a nested commit that ended Runlet's transaction, and statements on
 * connections nothing wrapped. Those become warnings, live and in the final `rollback` event.
 *
 * Where Runlet sees a statement before it runs (Laravel's beforeExecuting(), WordPress's `query`
 * filter, Doctrine's SQL logger and DBAL 4 middleware: guard()), it refuses an implicit commit
 * instead: \Runlet\DryRunRefused is thrown in the snippet and the statement never reaches the
 * database. A connection whose transaction can't begin stops the run: before the snippet, or,
 * for one that joins later, with an exception where the snippet opened it, after which every
 * statement on it is refused.
 *
 * Events (`rollback`): `state: begun` once the transactions are open, `state: warning` as soon
 * as something can't be rolled back (or was refused), and `state: finished` with each
 * connection's outcome.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class Rollback
{
    /** Drivers whose servers commit DDL (and a few other statements) implicitly. */
    private const IMPLICIT_COMMIT_DRIVERS = ['mysql', 'mariadb', 'mysqli', 'singlestore'];
    /** Eloquent drivers that aren't SQL databases: a transaction there isn't a dry run. */
    private const NOT_SQL = ['mongodb'];
    /** Warnings shown at most per run. */
    private const MAX_WARNINGS = 20;

    /** @var bool A dry run was asked for and has begun. */
    private static $active = false;
    /** @var bool Statements are counted (after begin(), until finish()). */
    private static $counting = false;
    /** @var int Runlet's own transaction statements are running: kept out of the Queries section. */
    private static $quiet = 0;
    /** @var bool */
    private static $finished = false;
    /** @var array<int, array<string, mixed>> Connections in the dry run, by spl_object_id. */
    private static $entries = [];
    /** @var array<string, int> Connection name => entry id. */
    private static $names = [];
    /** @var array<int, true> Database managers and event dispatchers already handled. */
    private static $seen = [];
    /** @var array<string, int> Statements that can change data on connections nothing wrapped, by name. */
    private static $unwrapped = [];
    /** @var array<int, array<string, mixed>> */
    private static $warnings = [];
    /** @var int Warnings left out by MAX_WARNINGS. */
    private static $omittedWarnings = 0;
    /** @var string[] Notes for the final report: what wasn't wrapped, and why. */
    private static $notes = [];
    /** @var bool Laravel announces the connections it opens later (ConnectionEstablished): they join too. */
    private static $watchingNew = false;

    /** Whether this run is a dry run (after begin()). */
    public static function isActive(): bool
    {
        return self::$active && !self::$finished;
    }

    /**
     * Begins the dry run: a transaction on every connection the driver's rollbackConnections()
     * returns. A driver whose hook throws stops the run before the snippet (the DriverFailure, or
     * the error, reaches Runner::main()), and so does a connection whose transaction can't begin
     * (\Runlet\DryRunRefused, with the database's error as its previous): the transactions that
     * did begin are rolled back by Runner::finish().
     */
    public static function begin(\Runlet\Driver $driver): void
    {
        $connections = Runner::callBootedDriver('rollbackConnections()', static function () use ($driver) {
            return $driver->rollbackConnections();
        });
        if (!is_array($connections)) {
            throw new \UnexpectedValueException($driver->name() . '::rollbackConnections() must return an array of connections.');
        }
        // Only now: a hook that fails leaves no dry run to report.
        self::$active = true;
        $inspector = \Runlet\Inspector::current();
        if ($inspector !== null) {
            $inspector->observeStatements(static function (string $sql, ?string $connection, array $details): bool {
                return self::observe($sql, $connection, $details);
            });
            $inspector->guardStatements(static function (string $sql, ?string $connection, array $details): void {
                self::guard($sql, $connection, $details);
            });
        }
        foreach ($connections as $key => $connection) {
            self::wrap(is_string($key) ? $key : null, $connection);
        }
        $failed = [];
        foreach (self::$entries as $entry) {
            if (!$entry['began'] && !$entry['ignored']) {
                $failed[] = $entry;
            }
        }
        if ($failed !== []) {
            // A dry run never runs code on a connection it can't roll back.
            $reasons = [];
            foreach ($failed as $entry) {
                $reasons[] = $entry['name'] . ' (' . self::label($entry) . '): ' . rtrim((string) $entry['error'], '.');
            }
            throw new \Runlet\DryRunRefused('Runlet couldn\'t begin a transaction on ' . implode('; and on ', $reasons) . '. A dry run runs nothing on a connection it can\'t roll back.', $failed[0]['exception']);
        }
        self::$counting = true;
        $open = [];
        foreach (self::$entries as $entry) {
            if ($entry['began']) {
                $open[] = ['name' => $entry['name'], 'driver' => $entry['driver'], 'api' => $entry['api'], 'status' => 'open'];
            }
        }
        Channel::emit('rollback', ['state' => 'begun', 'connections' => $open, 'watching' => self::watchesNewConnections()]);
        Runner::log('rollback', $open === [] && !self::watchesNewConnections()
            ? 'Rollback mode: no database connection to wrap in a transaction'
            : 'Rollback mode: began transactions on ' . ($open === [] ? 'no connection yet' : self::nameList(array_column($open, 'name')))
                . (self::watchesNewConnections() ? '; connections the snippet opens get one too' : ''),
            self::$notes === [] ? null : implode("\n", self::$notes));
    }

    /**
     * A connection opened during the run that should join the dry run (#208's WordPress PDO
     * when an SQL feature opens it). Does nothing outside a dry run. Throws
     * \Runlet\DryRunRefused when its transaction can't begin, so the caller never hands the
     * connection out.
     *
     * @param object $connection
     */
    public static function adopt($connection, ?string $name = null): void
    {
        if (self::isActive()) {
            self::wrap($name, $connection);
            self::stopUnlessBegun($connection);
        }
    }

    /**
     * @internal Inspector::query() reports every statement here first. True keeps the statement
     * out of the Queries section (Runlet's own BEGIN and ROLLBACK).
     *
     * @param array<string, mixed> $details
     */
    public static function observe(string $sql, ?string $connection, array $details): bool
    {
        if (self::$quiet > 0) {
            return true;
        }
        if (!self::$counting) {
            return false;
        }
        try {
            $id = self::entryId($connection, $details);
            if ($id !== null && self::$entries[$id]['ignored']) {
                return false;
            }
            if ($id !== null && ($details['executed'] ?? true) === false && self::refusal($id, $sql) !== null) {
                // Reported before it runs (the inspector's WordPress `query` filter): Runlet's own
                // filter, next, refuses it, so it never runs and isn't a query.
                return true;
            }
            [$kind, $keyword] = self::classify($sql);
            if ($id === null || !self::$entries[$id]['began']) {
                self::outside($id, $connection, $kind, $sql, $details);

                return false;
            }
            self::count($id, $kind, $keyword, $sql, $details);
        } catch (\Throwable $error) {
            // Counting must never break the code that ran the statement.
        }

        return false;
    }

    /**
     * Runlet's hooks that see a statement before it runs call this: Laravel's
     * beforeExecuting() and WordPress's `query` filter (installed by wrap()), and Doctrine's SQL
     * logger and DBAL 4 middleware (through Inspector::beforeStatement()). It throws
     * \Runlet\DryRunRefused, so the statement never reaches the database, for a statement MySQL
     * or MariaDB would commit Runlet's transaction with, and for any statement on a connection
     * whose transaction couldn't begin.
     *
     * @param array<string, mixed> $details `connectionId`, as observe() takes it
     */
    private static function guard(string $sql, ?string $connection, array $details): void
    {
        if (self::$quiet > 0 || !self::$counting) {
            return;
        }
        $id = self::entryId($connection, $details);
        $refusal = $id === null ? null : self::refusal($id, $sql);
        if ($refusal === null) {
            return;
        }
        $entry = self::$entries[$id];
        [$shown] = \Runlet\Inspector::clip(trim((string) preg_replace('/\s+/', ' ', $sql)), 200);
        $location = \Runlet\Inspector::callerLocation();
        $where = isset($location['snippetLine']) ? ' (line ' . $location['snippetLine'] . ')' : '';
        $message = 'Runlet refused ' . $shown . $where . ' on ' . $entry['name'] . ' before it ran. ' . $refusal
            . ' Nothing the snippet changed is saved: the dry run rolls it back as usual.';
        self::warn('refused', $message, $entry['name'], $shown, $location);
        throw new \Runlet\DryRunRefused(Channel::scrub('Dry run: ' . $message));
    }

    /**
     * Ends the dry run: rolls back every connection, then reports. Called once, from
     * Runner::finish(), whatever ended the run.
     */
    public static function finish(string $reason): void
    {
        if (!self::$active || self::$finished) {
            return;
        }
        self::$counting = false;
        self::$finished = true;
        $connections = [];
        $rolledBack = 0;
        $reads = 0;
        foreach (self::$entries as $id => $entry) {
            if ($entry['ignored']) {
                continue;
            }
            $entry = self::end($entry);
            self::$entries[$id] = $entry;
            $connections[] = self::describe($entry);
            if ($entry['began']) {
                $reads += $entry['reads'];
                if ($entry['status'] === 'rolledBack' || $entry['status'] === 'ended') {
                    $rolledBack += max(0, $entry['writes'] - $entry['saved']);
                }
            }
        }
        foreach (self::$unwrapped as $name => $count) {
            $connections[] = ['name' => $name, 'status' => 'notWrapped', 'saved' => $count, 'writes' => $count];
        }
        $payload = [
            'state' => 'finished',
            'reason' => $reason,
            'statements' => $rolledBack,
            'reads' => $reads,
            'connections' => $connections,
            'warnings' => self::$warnings,
        ];
        if (self::$omittedWarnings > 0) {
            $payload['omittedWarnings'] = self::$omittedWarnings;
        }
        if (self::$notes !== []) {
            $payload['notes'] = self::$notes;
        }
        if (self::watchesNewConnections()) {
            $payload['watching'] = true;
        }
        Channel::emit('rollback', $payload);
        $summary = [];
        foreach ($connections as $connection) {
            $summary[] = $connection['name'] . ': ' . $connection['status'] . (isset($connection['writes']) ? ' (' . $connection['writes'] . ' changing, ' . ($connection['saved'] ?? 0) . ' saved)' : '');
        }
        Runner::log('rollback', 'Rollback mode: rolled back ' . $rolledBack . ' statement' . ($rolledBack === 1 ? '' : 's') . ' after the run (' . $reason . ')', $summary === [] ? null : implode("\n", $summary));
    }

    /**
     * What a statement does, from its first keyword: `read`, `write`, `ddl` (schema and the
     * other statements MySQL commits implicitly), `begin`, `commit`, `rollback` (of the whole
     * transaction), `savepoint`, or `session` (SET, USE: no data). Leading comments and
     * parentheses are skipped.
     *
     * @return array{0: string, 1: string} the kind and the keyword (upper case)
     */
    public static function classify(string $sql): array
    {
        $text = (string) preg_replace('~^(\s|\(|--[^\n]*(\n|$)|#[^\n]*(\n|$)|/\*.*?\*/)+~s', '', $sql);
        // DBAL 2 and 3 log transaction control as quoted pseudo statements ("COMMIT").
        $text = ltrim($text, '"');
        if (!preg_match('/^([A-Za-z_]+)(?:\s+([A-Za-z_]+))?(?:\s+([A-Za-z_]+))?/', $text, $match)) {
            return ['write', ''];
        }
        $first = strtoupper($match[1]);
        $second = strtoupper($match[2] ?? '');
        $third = strtoupper($match[3] ?? '');
        switch ($first) {
            case 'SELECT':
            case 'SHOW':
            case 'DESCRIBE':
            case 'DESC':
            case 'EXPLAIN':
            case 'VALUES':
            case 'TABLE':
            case 'PRAGMA':
                return ['read', $first];
            case 'WITH':
                return [preg_match('/\b(INSERT|UPDATE|DELETE|MERGE)\b/i', $text) ? 'write' : 'read', $first];
            case 'BEGIN':
            case 'START':
                return [$first === 'START' && $second !== 'TRANSACTION' ? 'write' : 'begin', $first];
            case 'COMMIT':
            case 'END':
                return ['commit', $first];
            case 'ROLLBACK':
                return [$second === 'TO' || ($second === 'WORK' && $third === 'TO') ? 'savepoint' : 'rollback', $first];
            case 'SAVEPOINT':
            case 'RELEASE':
                return ['savepoint', $first];
            case 'SET':
                // SET autocommit = 1 commits the open transaction on MySQL.
                return [preg_match('/^SET\s+(@@(session\.)?|SESSION\s+)?autocommit\s*(=|:=)\s*(1|ON|TRUE)\b/i', $text) ? 'ddl' : 'session', $first];
            case 'USE':
                return ['session', $first];
            case 'CREATE':
            case 'DROP':
                // A temporary table commits nothing on MySQL.
                return [$second === 'TEMPORARY' || $second === 'TEMP' ? 'write' : 'ddl', $first];
            case 'ALTER':
            case 'RENAME':
            case 'TRUNCATE':
            case 'LOCK':
            case 'UNLOCK':
            case 'GRANT':
            case 'REVOKE':
            case 'ANALYZE':
            case 'OPTIMIZE':
            case 'REPAIR':
            case 'FLUSH':
            case 'RESET':
            case 'INSTALL':
            case 'UNINSTALL':
            case 'CACHE':
                return ['ddl', $first];
            case 'LOAD':
                return [$second === 'INDEX' ? 'ddl' : 'write', $first];
            default:
                return ['write', $first];
        }
    }

    /**
     * Adds one connection, or the connections a manager holds, to the dry run.
     *
     * @param mixed $object
     */
    private static function wrap(?string $name, $object): void
    {
        try {
            if (!is_object($object)) {
                self::note('rollbackConnections() returned ' . gettype($object) . ($name !== null ? ' for "' . $name . '"' : '') . ', not a connection; Runlet skipped it.');

                return;
            }
            if (is_a($object, 'Illuminate\Database\Capsule\Manager')) {
                $object = $object->getDatabaseManager();
            }
            if (is_a($object, 'Illuminate\Database\DatabaseManager')) {
                self::wrapManager($object);
            } elseif (is_a($object, 'Illuminate\Database\ConnectionResolver')) {
                $connections = self::property($object, 'connections');
                foreach (is_array($connections) ? $connections : [] as $connection) {
                    self::wrap(null, $connection);
                }
            } elseif (is_a($object, 'Illuminate\Database\Connection')) {
                self::wrapEloquent($object);
            } elseif (is_a($object, 'Doctrine\DBAL\Connection')) {
                self::wrapDoctrine($name ?? 'doctrine', $object);
            } elseif (is_a($object, 'Doctrine\Persistence\ConnectionRegistry') || is_a($object, 'Doctrine\Common\Persistence\ConnectionRegistry')) {
                foreach ($object->getConnections() as $connectionName => $connection) {
                    self::wrap((string) $connectionName, $connection);
                }
            } elseif (is_a($object, 'wpdb')) {
                self::wrapWpdb($name ?? 'wpdb', $object);
            } elseif ($object instanceof \PDO) {
                self::wrapPdo($name ?? 'pdo', $object);
            } else {
                self::note('Runlet can\'t wrap ' . \Runlet\Inspector::className(get_class($object)) . ($name !== null ? ' ("' . $name . '")' : '') . ' in a transaction: rollbackConnections() can return Eloquent, Doctrine DBAL, $wpdb, and PDO connections.');
            }
        } catch (\Throwable $error) {
            self::note('Runlet couldn\'t wrap ' . ($name !== null ? '"' . $name . '"' : 'a connection') . ': ' . self::message($error));
        }
    }

    /**
     * Laravel's DatabaseManager (or Capsule's): its open connections now, and every connection
     * it opens during the run when the application announces them (ConnectionEstablished,
     * Laravel 9.49+); without that event, the default connection now.
     *
     * @param object $manager
     */
    private static function wrapManager($manager): void
    {
        $managerId = spl_object_id($manager);
        if (isset(self::$seen[$managerId])) {
            return;
        }
        self::$seen[$managerId] = true;
        foreach ($manager->getConnections() as $connection) {
            self::wrap(null, $connection);
        }
        $container = self::property($manager, 'app');
        $events = null;
        if (is_object($container) && method_exists($container, 'bound') && $container->bound('events')) {
            $events = $container->make('events');
        }
        if (is_object($events) && method_exists($events, 'listen') && class_exists('Illuminate\Database\Events\ConnectionEstablished')) {
            $events->listen('Illuminate\Database\Events\ConnectionEstablished', static function ($event): void {
                if (self::isActive() && isset($event->connection) && is_object($event->connection)) {
                    self::wrap(null, $event->connection);
                    // Thrown out of DB::connection(), where the snippet opened it.
                    self::stopUnlessBegun($event->connection);
                }
            });
            self::$watchingNew = true;

            return;
        }
        // Without the event, connections opened later can't join: begin on the default now.
        $default = $manager->connection();
        self::wrap(null, $default);
        self::note('Connections other than ' . $default->getName() . ' that the snippet opens aren\'t in the dry run: Runlet learns about new connections from illuminate/database\'s ConnectionEstablished event, which needs Laravel 9.49 or later and an event dispatcher.');
    }

    /** @param object $connection an Illuminate\Database\Connection */
    private static function wrapEloquent($connection): void
    {
        $id = spl_object_id($connection);
        if (isset(self::$entries[$id])) {
            return;
        }
        $name = (string) $connection->getName();
        $driver = strtolower((string) $connection->getDriverName());
        $entry = self::entry($name, $driver, 'eloquent', $connection);
        if (in_array($driver, self::NOT_SQL, true)) {
            // Its statements aren't SQL, and a transaction there needs a replica set: left alone.
            $entry['ignored'] = true;
            self::register($id, $entry);
            self::note('"' . $name . '" (' . $driver . ') isn\'t in the dry run: Runlet rolls back SQL databases only, so what the snippet writes there is saved.');

            return;
        }
        $entry['level'] = (int) $connection->transactionLevel();
        self::listenToEloquentTransactions($connection);
        if (method_exists($connection, 'beforeExecuting')) {
            // Laravel 8+ calls it before every statement in Connection::run(): an implicit commit
            // is refused before it reaches the server. Installed before the transaction begins,
            // so a connection whose transaction can't begin runs nothing.
            $connection->beforeExecuting(static function ($query) use ($id): void {
                self::guard(is_string($query) ? $query : (is_object($query) && method_exists($query, '__toString') ? (string) $query : ''), null, ['connectionId' => $id]);
            });
        }
        $entry = self::open($entry, static function () use ($connection): void {
            $connection->beginTransaction();
        });
        self::register($id, $entry);
    }

    /**
     * Notices a commit or rollback in the application's code that ends Runlet's transaction:
     * Laravel's TransactionCommitted and TransactionRolledBack events, after which the
     * connection's level is below Runlet's.
     *
     * @param object $connection
     */
    private static function listenToEloquentTransactions($connection): void
    {
        $events = method_exists($connection, 'getEventDispatcher') ? $connection->getEventDispatcher() : null;
        if (!is_object($events) || !method_exists($events, 'listen') || isset(self::$seen[spl_object_id($events)])) {
            return;
        }
        self::$seen[spl_object_id($events)] = true;
        $listener = static function ($event, string $what): void {
            $connection = $event->connection ?? null;
            if (!self::$counting || self::$quiet > 0 || !is_object($connection) || !isset(self::$entries[spl_object_id($connection)])) {
                return;
            }
            $id = spl_object_id($connection);
            $entry = self::$entries[$id];
            if ($entry['began'] && $entry['open'] && (int) $connection->transactionLevel() <= $entry['level']) {
                self::ended($id, $what, $what === 'commit' ? 'DB::commit()' : 'DB::rollBack()', []);
            }
        };
        $events->listen('Illuminate\Database\Events\TransactionCommitted', static function ($event) use ($listener): void {
            $listener($event, 'commit');
        });
        $events->listen('Illuminate\Database\Events\TransactionRolledBack', static function ($event) use ($listener): void {
            $listener($event, 'rollback');
        });
    }

    /** @param object $connection a Doctrine\DBAL\Connection */
    private static function wrapDoctrine(string $name, $connection): void
    {
        $id = spl_object_id($connection);
        if (isset(self::$entries[$id])) {
            return;
        }
        $entry = self::entry($name, self::doctrineDriver($connection), 'doctrine', $connection);
        $entry['level'] = (int) $connection->getTransactionNestingLevel();
        $inspector = \Runlet\Inspector::current();
        if ($inspector !== null) {
            // Counts its statements even when the driver's inspect() didn't hook it.
            DatabaseHooks::doctrine($inspector, $connection, $name);
        }
        $entry = self::open($entry, static function () use ($connection): void {
            $connection->beginTransaction();
        });
        if ($entry['began'] && $entry['driver'] === '') {
            $entry['driver'] = self::doctrinePlatform($connection);
        }
        self::register($id, $entry);
    }

    /** @param object $wpdb */
    private static function wrapWpdb(string $name, $wpdb): void
    {
        $id = spl_object_id($wpdb);
        if (isset(self::$entries[$id])) {
            return;
        }
        $entry = self::entry($name, is_a($wpdb, 'WP_SQLite_DB') ? 'sqlite' : 'mysql', 'wordpress', $wpdb);
        if (function_exists('add_filter')) {
            // $wpdb->query() passes every statement through `query` before it runs: last, so this
            // sees the statement other filters made. Throwing here leaves $wpdb untouched.
            add_filter('query', static function ($query) use ($id) {
                if (is_string($query)) {
                    self::guard($query, null, ['connectionId' => $id]);
                }

                return $query;
            }, PHP_INT_MAX, 1);
        }
        $entry = self::open($entry, static function () use ($wpdb): void {
            self::wpdbQuery($wpdb, 'START TRANSACTION');
        });
        self::register($id, $entry);
    }

    private static function wrapPdo(string $name, \PDO $pdo): void
    {
        $id = spl_object_id($pdo);
        if (isset(self::$entries[$id])) {
            return;
        }
        $entry = self::entry($name, strtolower((string) $pdo->getAttribute(\PDO::ATTR_DRIVER_NAME)), 'pdo', $pdo);
        if ($pdo->inTransaction()) {
            $entry['error'] = 'it was already in a transaction, which Runlet can\'t nest on a plain PDO';
            self::notStarted($entry);
            self::register($id, $entry);

            return;
        }
        $inspector = \Runlet\Inspector::current();
        if ($inspector !== null && !$inspector->watchPdo($pdo, $name)) {
            self::note('Statements on "' . $name . '" (PDO) aren\'t counted: the run inspector can\'t watch that connection.');
        }
        $entry = self::open($entry, static function () use ($pdo): void {
            $pdo->beginTransaction();
        });
        self::register($id, $entry);
    }

    /**
     * @param object $connection
     * @return array<string, mixed>
     */
    private static function entry(string $name, string $driver, string $api, $connection): array
    {
        return [
            'name' => $name,
            'driver' => $driver,
            'api' => $api,
            'object' => $connection,
            // The transaction level before Runlet's (Eloquent, Doctrine): rolled back to it.
            'level' => 0,
            'began' => false,
            // Runlet's transaction is open: statements that change data are rolled back.
            'open' => false,
            'error' => null,
            // Why the transaction couldn't begin, as thrown (the stop's previous error).
            'exception' => null,
            'reads' => 0,
            // Statements that can change data, and how many of them are saved anyway.
            'writes' => 0,
            'saved' => 0,
            // What ended the transaction before Runlet rolled it back, in order.
            'commits' => [],
            'status' => 'notStarted',
            'ignored' => false,
        ];
    }

    /**
     * Runs $begin quietly and records whether the transaction began.
     *
     * @param array<string, mixed> $entry
     * @return array<string, mixed>
     */
    private static function open(array $entry, \Closure $begin): array
    {
        self::$quiet++;
        try {
            $begin();
            $entry['began'] = true;
            $entry['open'] = true;
            $entry['status'] = 'open';
        } catch (\Throwable $error) {
            $entry['error'] = self::message($error);
            $entry['exception'] = $error;
        } finally {
            self::$quiet--;
        }
        if ($entry['began']) {
            if (self::$counting) {
                Runner::log('rollback', 'Began a transaction on ' . $entry['name'] . ' (' . self::label($entry) . '), opened during the run');
            }
        } else {
            self::notStarted($entry);
        }

        return $entry;
    }

    /**
     * Reports a transaction that couldn't begin. The run stops: begin() before the snippet, or
     * stopUnlessBegun() where the snippet opened the connection.
     *
     * @param array<string, mixed> $entry
     */
    private static function notStarted(array $entry): void
    {
        $error = rtrim((string) $entry['error'], '.');
        self::warn('notStarted', self::$counting
            ? 'Runlet couldn\'t begin a transaction on ' . $entry['name'] . ', which the snippet opened: ' . $error . '. A dry run runs nothing on a connection it can\'t roll back: Runlet stopped the run there, and refuses every statement on ' . $entry['name'] . '.'
            : 'Runlet couldn\'t begin a transaction on ' . $entry['name'] . ': ' . $error . '. A dry run runs nothing on a connection it can\'t roll back, so nothing ran.',
            $entry['name'], null, self::$counting ? \Runlet\Inspector::callerLocation() : []);
    }

    /** @param array<string, mixed> $entry */
    private static function register(int $id, array $entry): void
    {
        self::$entries[$id] = $entry;
        self::$names[$entry['name']] = $id;
    }

    /**
     * The entry a statement ran on: by `details.connectionId` (Runlet's own hooks), else by
     * connection name.
     *
     * @param array<string, mixed> $details
     */
    private static function entryId(?string $connection, array $details): ?int
    {
        if (isset($details['connectionId']) && is_int($details['connectionId']) && isset(self::$entries[$details['connectionId']])) {
            return $details['connectionId'];
        }
        if ($connection !== null && isset(self::$names[$connection])) {
            return self::$names[$connection];
        }

        return null;
    }

    /**
     * Why the dry run can't let a statement run on a connection, or null when it can: a statement
     * that would commit Runlet's open transaction implicitly (DDL, LOCK TABLES, SET autocommit = 1
     * and the other `ddl` statements on MySQL and MariaDB; a new transaction there and in
     * WordPress's SQLite drop-in), or anything on a connection whose transaction couldn't begin.
     * Temporary tables are `write`s, and Runlet's own statements never get here.
     */
    private static function refusal(int $id, string $sql): ?string
    {
        $entry = self::$entries[$id];
        if ($entry['ignored']) {
            return null;
        }
        if (!$entry['began']) {
            return 'Runlet couldn\'t begin a transaction on ' . $entry['name'] . ' (' . rtrim((string) $entry['error'], '.') . '), and a dry run runs nothing on a connection it can\'t roll back.';
        }
        if (!$entry['open']) {
            // Runlet's transaction already ended (a commit in the code): nothing left to protect.
            return null;
        }
        [$kind] = self::classify($sql);
        $commitsDdl = in_array($entry['driver'], self::IMPLICIT_COMMIT_DRIVERS, true);
        if ($kind === 'ddl' && $commitsDdl) {
            return 'MySQL and MariaDB commit it at once, with everything before it, even inside a transaction, so a dry run can\'t roll it back. Turn off Dry Run to run it.';
        }
        if ($kind === 'begin' && ($commitsDdl || $entry['api'] === 'wordpress')) {
            return 'Starting a transaction commits the open one on ' . ($commitsDdl ? 'MySQL and MariaDB' : 'WordPress\'s SQLite drop-in, as on MySQL') . ', so a dry run can\'t roll back what came before it. Turn off Dry Run to run it.';
        }

        return null;
    }

    /**
     * A connection that joined during the run (ConnectionEstablished, adopt()) and whose
     * transaction couldn't begin stops the snippet where it opened it. guard() refuses every
     * later statement on it, so a snippet that catches the exception still can't run anything
     * there outside a transaction.
     *
     * @param object $connection
     */
    private static function stopUnlessBegun($connection): void
    {
        $entry = self::$entries[spl_object_id($connection)] ?? null;
        if ($entry === null || $entry['began'] || $entry['ignored']) {
            return;
        }
        $location = \Runlet\Inspector::callerLocation();
        $where = isset($location['snippetLine']) ? ' (line ' . $location['snippetLine'] . ')' : '';
        throw new \Runlet\DryRunRefused(Channel::scrub('Dry run: Runlet couldn\'t begin a transaction on ' . $entry['name'] . ' (' . self::label($entry) . '), which the snippet opened' . $where . ': '
            . rtrim((string) $entry['error'], '.') . '. A dry run runs nothing on a connection it can\'t roll back, so Runlet stopped the run here and refuses every statement on ' . $entry['name'] . '. What the snippet changed elsewhere is rolled back as usual; turn off Dry Run to run it without a transaction.'), $entry['exception']);
    }

    /**
     * Counts a statement on a wrapped connection and notices what ends its transaction.
     *
     * @param array<string, mixed> $details
     */
    private static function count(int $id, string $kind, string $keyword, string $sql, array $details): void
    {
        $entry = self::$entries[$id];
        // MySQL and MariaDB (and WordPress on them) commit DDL implicitly; a new transaction
        // commits the open one there, and in WordPress's SQLite drop-in, which acts like MySQL.
        $commitsDdl = in_array($entry['driver'], self::IMPLICIT_COMMIT_DRIVERS, true);
        $beginCommits = $commitsDdl || $entry['api'] === 'wordpress';
        switch ($kind) {
            case 'read':
                self::$entries[$id]['reads']++;
                break;
            case 'session':
            case 'savepoint':
                break;
            case 'begin':
                if ($beginCommits && $entry['open']) {
                    self::ended($id, 'begin', $sql, $details);
                }
                break;
            case 'commit':
            case 'rollback':
                if ($entry['open']) {
                    self::ended($id, $kind, $sql, $details);
                }
                break;
            case 'ddl':
                self::$entries[$id]['writes']++;
                if (!$entry['open']) {
                    self::$entries[$id]['saved']++;
                } elseif ($commitsDdl) {
                    self::ended($id, 'implicit', $sql, $details);
                }
                break;
            default:
                self::$entries[$id]['writes']++;
                if (!$entry['open']) {
                    self::$entries[$id]['saved']++;
                }
        }
    }

    /**
     * The transaction on a connection ended before Runlet rolled it back: what changed before
     * is saved (or, after a rollback of the application's, undone). After an implicit commit
     * Runlet begins a new transaction at once, where it can, so what follows is still rolled
     * back; otherwise everything after runs without a transaction and is saved.
     *
     * @param array<string, mixed> $details
     */
    private static function ended(int $id, string $how, string $statement, array $details): void
    {
        $location = self::location($details);
        $entry = self::$entries[$id];
        if ($how !== 'rollback') {
            $entry['saved'] = $entry['writes'];
        }
        $entry['open'] = false;
        [$shown] = \Runlet\Inspector::clip(trim((string) preg_replace('/\s+/', ' ', $statement)), 200);
        // Only after the statement ran: WordPress's `query` filter reports it before.
        $reopened = $how === 'implicit' && ($details['executed'] ?? true) !== false && self::reopen($entry);
        $entry['open'] = $reopened;
        $commit = ['how' => $how, 'sql' => $shown];
        if ($reopened) {
            $commit['reopened'] = true;
        }
        $entry['commits'][] = $commit + array_intersect_key($location, array_flip(['inSnippet', 'snippetLine', 'file', 'line']));
        self::$entries[$id] = $entry;
        $where = isset($location['snippetLine']) ? ' (line ' . $location['snippetLine'] . ')' : '';
        $after = $reopened
            ? ' Runlet began a new transaction right after it, so what the snippet changes there from then on is rolled back.'
            : ' Everything after it on ' . $entry['name'] . ' runs without a transaction and is saved too.';
        switch ($how) {
            case 'implicit':
                $message = $shown . $where . ' committed the transaction on ' . $entry['name'] . ': MySQL and MariaDB commit schema changes (and statements such as LOCK TABLES) at once, even inside a transaction. It is saved, and so is what the snippet changed there before it.' . $after;
                break;
            case 'begin':
                $message = $shown . $where . ' started a new transaction on ' . $entry['name'] . ', which commits the open one on ' . ($entry['driver'] === 'sqlite' ? 'WordPress\'s SQLite drop-in, as on MySQL' : 'MySQL and MariaDB') . ': what the snippet changed there before it is saved, and so is what that transaction commits.';
                break;
            case 'commit':
                $message = $shown . $where . ' committed Runlet\'s transaction on ' . $entry['name'] . ': a commit that isn\'t inside a transaction of the snippet\'s own. What the snippet changed there before it is saved.' . $after;
                break;
            default:
                $message = $shown . $where . ' rolled back Runlet\'s transaction on ' . $entry['name'] . ' early: what the snippet changed there before it is undone.' . $after;
        }
        self::warn($how === 'rollback' ? 'rolledBackEarly' : ($how === 'implicit' ? 'implicitCommit' : 'committed'), $message, $entry['name'], $shown, $location);
    }

    /**
     * Begins a new transaction on a connection whose transaction the database just committed
     * implicitly, underneath the framework (whose own level still counts Runlet's): a plain
     * START TRANSACTION on the connection's PDO, mysqli, or $wpdb.
     *
     * @param array<string, mixed> $entry
     */
    private static function reopen(array $entry): bool
    {
        $connection = $entry['object'];
        self::$quiet++;
        try {
            switch ($entry['api']) {
                case 'eloquent':
                    $native = $connection->getPdo();
                    break;
                case 'doctrine':
                    $native = self::doctrineNative($connection);
                    break;
                case 'wordpress':
                    self::wpdbQuery($connection, 'START TRANSACTION');

                    return true;
                default:
                    $native = $connection;
            }
            if ($native instanceof \PDO || $native instanceof \mysqli) {
                // PDO::beginTransaction() would refuse on PHP 7.4, whose flag still says "open".
                $native->query('START TRANSACTION');

                return true;
            }
        } catch (\Throwable $error) {
            Runner::log('rollback', 'Couldn\'t begin a new transaction on ' . $entry['name'] . ' after an implicit commit: ' . self::message($error));
        } finally {
            self::$quiet--;
        }

        return false;
    }

    /**
     * A statement on a connection that isn't in the dry run (never wrapped, or its transaction
     * didn't begin): changes there are saved.
     *
     * @param array<string, mixed> $details
     */
    private static function outside(?int $id, ?string $connection, string $kind, string $sql, array $details): void
    {
        if (in_array($kind, ['read', 'session', 'savepoint'], true)) {
            return;
        }
        if ($id !== null) {
            self::$entries[$id]['writes']++;
            self::$entries[$id]['saved']++;

            return;
        }
        $name = $connection !== null && $connection !== '' ? $connection : 'an unnamed connection';
        $first = !isset(self::$unwrapped[$name]);
        self::$unwrapped[$name] = (self::$unwrapped[$name] ?? 0) + 1;
        if ($first) {
            [$shown] = \Runlet\Inspector::clip(trim((string) preg_replace('/\s+/', ' ', $sql)), 200);
            $location = self::location($details);
            $where = isset($location['snippetLine']) ? ' (line ' . $location['snippetLine'] . ')' : '';
            self::warn('notWrapped', $shown . $where . ' ran on ' . $name . ', a connection this dry run doesn\'t wrap: what it changes is saved.', $name, $shown, $location);
        }
    }

    /**
     * Rolls back one connection and works out what happened to it.
     *
     * @param array<string, mixed> $entry
     * @return array<string, mixed>
     */
    private static function end(array $entry): array
    {
        if (!$entry['began']) {
            return $entry;
        }
        $connection = $entry['object'];
        // Whether the database still had a transaction open, when the driver can tell.
        $stillOpen = null;
        self::$quiet++;
        try {
            switch ($entry['api']) {
                case 'eloquent':
                    $stillOpen = self::pdoInTransaction(method_exists($connection, 'getRawPdo') ? $connection->getRawPdo() : $connection->getPdo());
                    if ((int) $connection->transactionLevel() <= $entry['level']) {
                        // The snippet's code committed or rolled back Runlet's level itself.
                        $stillOpen = $stillOpen === true && $entry['open'];
                        if ($stillOpen) {
                            $connection->getPdo()->rollBack();
                        }
                    } else {
                        $connection->rollBack($entry['level']);
                    }
                    break;
                case 'doctrine':
                    $native = self::doctrineNative($connection);
                    $stillOpen = $native instanceof \PDO ? self::pdoInTransaction($native) : null;
                    if ((int) $connection->getTransactionNestingLevel() <= $entry['level']) {
                        $stillOpen = false;
                    }
                    for ($guard = 0; $guard < 100 && (int) $connection->getTransactionNestingLevel() > $entry['level']; $guard++) {
                        $connection->rollBack();
                    }
                    break;
                case 'wordpress':
                    if ($entry['open']) {
                        self::wpdbQuery($connection, 'ROLLBACK');
                    }
                    break;
                case 'pdo':
                    $stillOpen = $connection->inTransaction();
                    if ($stillOpen) {
                        $connection->rollBack();
                    }
                    break;
            }
            if (!$entry['open']) {
                $last = end($entry['commits']);
                $entry['status'] = is_array($last) && $last['how'] === 'rollback' ? 'ended' : 'committed';
            } elseif ($stillOpen === false) {
                // The transaction was gone, and Runlet saw nothing end it: the changes are saved.
                $entry['status'] = 'lost';
                $entry['saved'] = $entry['writes'];
            } else {
                $entry['status'] = 'rolledBack';
            }
        } catch (\Throwable $error) {
            $entry['status'] = $entry['open'] ? 'failed' : 'committed';
            $entry['error'] = self::message($error);
        } finally {
            self::$quiet--;
        }

        return $entry;
    }

    /**
     * The final report's line for one connection.
     *
     * @param array<string, mixed> $entry
     * @return array<string, mixed>
     */
    private static function describe(array $entry): array
    {
        $result = [
            'name' => $entry['name'],
            'driver' => $entry['driver'],
            'api' => $entry['api'],
            'status' => $entry['began'] ? $entry['status'] : 'notStarted',
            'writes' => $entry['writes'],
            'reads' => $entry['reads'],
            'saved' => min($entry['writes'], $entry['saved']),
        ];
        if ($entry['error'] !== null) {
            $result['error'] = Channel::scrub((string) $entry['error']);
        }
        if ($entry['commits'] !== []) {
            $result['commits'] = array_slice($entry['commits'], 0, 5);
        }

        return $result;
    }

    /**
     * @param array<string, mixed> $location
     */
    private static function warn(string $kind, string $message, ?string $connection, ?string $sql, array $location): void
    {
        if (count(self::$warnings) >= self::MAX_WARNINGS) {
            self::$omittedWarnings++;

            return;
        }
        $warning = ['kind' => $kind, 'message' => Channel::scrub($message)];
        if ($connection !== null) {
            $warning['connection'] = $connection;
        }
        if ($sql !== null) {
            $warning['sql'] = Channel::scrub($sql);
        }
        foreach (['inSnippet', 'snippetLine', 'file', 'line'] as $key) {
            if (isset($location[$key])) {
                $warning[$key] = $location[$key];
            }
        }
        self::$warnings[] = $warning;
        Channel::emit('rollback', ['state' => 'warning', 'warning' => $warning]);
    }

    private static function note(string $note): void
    {
        if (count(self::$notes) < self::MAX_WARNINGS && !in_array($note, self::$notes, true)) {
            self::$notes[] = Channel::scrub($note);
        }
    }

    /**
     * Where a statement came from: the inspector's `location` detail, else the caller.
     *
     * @param array<string, mixed> $details
     * @return array<string, mixed>
     */
    private static function location(array $details): array
    {
        return isset($details['location']) && is_array($details['location']) ? $details['location'] : \Runlet\Inspector::callerLocation();
    }

    private static function watchesNewConnections(): bool
    {
        return self::$watchingNew;
    }

    /** @param object $wpdb */
    private static function wpdbQuery($wpdb, string $sql): void
    {
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
            throw new \RuntimeException($error !== '' ? $error : 'WordPress could not run ' . $sql . '.');
        }
    }

    /** @param mixed $pdo */
    private static function pdoInTransaction($pdo): ?bool
    {
        if (!$pdo instanceof \PDO) {
            return null;
        }
        // PHP 7.4's pdo_mysql reports its own flag, not the server's; only PHP 8 sees an implicit commit.
        if (PHP_VERSION_ID < 80000 && $pdo->getAttribute(\PDO::ATTR_DRIVER_NAME) === 'mysql') {
            return null;
        }

        return $pdo->inTransaction();
    }

    /**
     * @param object $connection
     * @return mixed
     */
    private static function doctrineNative($connection)
    {
        try {
            if (method_exists($connection, 'getNativeConnection')) {
                return $connection->getNativeConnection();
            }
            if (method_exists($connection, 'getWrappedConnection')) {
                return $connection->getWrappedConnection();
            }
        } catch (\Throwable $error) {
            return null;
        }

        return null;
    }

    /** @param object $connection */
    private static function doctrineDriver($connection): string
    {
        $params = method_exists($connection, 'getParams') ? $connection->getParams() : [];
        $driver = isset($params['driver']) && is_string($params['driver']) ? strtolower($params['driver']) : '';
        $driver = (string) preg_replace('/^pdo_/', '', $driver);
        $map = ['mysqli' => 'mysql', 'sqlite3' => 'sqlite', 'pgsql' => 'pgsql', 'sqlsrv' => 'sqlsrv', 'mysql' => 'mysql', 'sqlite' => 'sqlite'];

        return $map[$driver] ?? $driver;
    }

    /** @param object $connection */
    private static function doctrinePlatform($connection): string
    {
        try {
            $platform = strtolower(get_class($connection->getDatabasePlatform()));
        } catch (\Throwable $error) {
            return '';
        }
        foreach (['mariadb' => 'mysql', 'mysql' => 'mysql', 'postgre' => 'pgsql', 'sqlite' => 'sqlite', 'sqlserver' => 'sqlsrv'] as $needle => $driver) {
            if (strpos($platform, $needle) !== false) {
                return $driver;
            }
        }

        return '';
    }

    /** @param array<string, mixed> $entry */
    private static function label(array $entry): string
    {
        return $entry['driver'] === '' ? $entry['api'] : $entry['api'] . ', ' . $entry['driver'];
    }

    /** @param string[] $names */
    private static function nameList(array $names): string
    {
        return implode(', ', array_unique($names));
    }

    private static function message(\Throwable $error): string
    {
        return Channel::scrub(trim($error->getMessage()) !== '' ? trim($error->getMessage()) : get_class($error));
    }

    /**
     * @param object $object
     * @return mixed
     */
    private static function property($object, string $property)
    {
        try {
            $reflection = new \ReflectionProperty($object, $property);
            if (PHP_VERSION_ID < 80100) {
                $reflection->setAccessible(true);
            }

            return $reflection->getValue($object);
        } catch (\Throwable $error) {
            return null;
        }
    }
}

/**
 * @internal The inspector's database hooks for the runner's own use: a Doctrine connection in
 * the dry run gets its statements counted even when the driver's inspect() didn't hook it.
 */
final class DatabaseHooks
{
    use \Runlet\InspectsDatabases;

    /** @param object $connection */
    public static function doctrine(\Runlet\Inspector $inspector, $connection, string $name): void
    {
        (new self())->inspectDoctrine($inspector, $connection, $name);
    }
}

namespace Runlet;

/**
 * A dry run (#13) refused a statement before it reached the database: one MySQL or MariaDB
 * would commit the dry run's transaction with (DDL, LOCK TABLES, START TRANSACTION, …), or any
 * statement on a connection whose transaction couldn't begin. Also thrown where the snippet
 * opens a connection whose transaction can't begin. Nothing the snippet changed is saved; turn
 * off Dry Run to run the statement.
 */
final class DryRunRefused extends \RuntimeException
{
    /** @internal Thrown by Runlet only. */
    public function __construct(string $message, ?\Throwable $previous = null)
    {
        parent::__construct($message, 0, $previous);
        // Thrown deep inside the database layer, from Runlet's own hook: it is reported at the
        // snippet line that led there, else at the first frame outside the runner.
        $fallback = null;
        foreach ($this->getTrace() as $frame) {
            $file = $frame['file'] ?? null;
            if (!is_string($file)) {
                continue;
            }
            if (\RunletRunner\Runner::isSnippetFile($file)) {
                $this->file = $file;
                $this->line = (int) ($frame['line'] ?? 0);

                return;
            }
            if ($fallback === null && strpos($file, __FILE__) !== 0) {
                $fallback = $frame;
            }
        }
        if ($fallback !== null) {
            $this->file = (string) $fallback['file'];
            $this->line = (int) ($fallback['line'] ?? 0);
        }
    }
}
