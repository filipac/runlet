<?php

declare(strict_types=1);

/*
 * Saved database connections (#138): a connection the user saved for a target, opened in
 * the target's own PHP (local PHP, `docker exec`, SSH). The app sends its definition and
 * password in the runner request, which reaches PHP only on stdin; Runner::main() hands the
 * definition to SqlConnect::configure() and drops it from the request before anything else
 * runs, and the run boots no project code (the `plain` bootstrap).
 *
 * The password:
 *  - is never a function argument: connect() reads it from a private property, and the
 *    run sets zend.exception_ignore_args, so no exception trace carries it;
 *  - is forgotten once the connection is open (Channel keeps what it needs to scrub);
 *  - never leaves in an event: Channel::emit() replaces it (and its URL-encoded forms)
 *    with ••• in every message, and PDO's errors are rethrown with their message only.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class SqlConnect
{
    private const DRIVERS = ['mysql', 'pgsql', 'sqlite'];

    /** @var array{id: string, name: string, driver: string, host: string, port: int|null, database: string, user: string, timeout: int, summary: string}|null */
    private static $definition;
    /** @var string|null The password, until the connection is open. */
    private static $password;
    /** @var \PDO|null */
    private static $pdo;
    /** @var float|null */
    private static $connectMs;

    /**
     * Takes the saved connection from the runner request. Called by Runner::main() before
     * the bootstrap; the caller removes it from the request.
     *
     * @param array<string, mixed> $connection
     */
    public static function configure(array $connection): void
    {
        $password = isset($connection['password']) && is_string($connection['password']) ? $connection['password'] : null;
        unset($connection['password']);
        self::$definition = [
            'id' => (string) ($connection['id'] ?? ''),
            'name' => (string) ($connection['name'] ?? ''),
            'driver' => (string) ($connection['driver'] ?? ''),
            'host' => (string) ($connection['host'] ?? ''),
            'port' => isset($connection['port']) ? (int) $connection['port'] : null,
            'database' => (string) ($connection['database'] ?? ''),
            'user' => (string) ($connection['user'] ?? ''),
            'timeout' => max(1, min(300, (int) ($connection['timeout'] ?? 10))),
            'summary' => (string) ($connection['summary'] ?? ''),
        ];
        self::$password = $password;
        if ($password !== null && $password !== '') {
            Channel::addSecret($password);
        }
    }

    public static function isConfigured(): bool
    {
        return self::$definition !== null;
    }

    /** The saved connection's name. */
    public static function name(): string
    {
        return self::$definition['name'] ?? '';
    }

    /** Where results say they came from: `saved connection "Reporting" (pgsql, db:5432/reports)`. */
    public static function origin(): string
    {
        $definition = self::$definition ?? [];
        $summary = (string) ($definition['summary'] ?? '');

        return 'saved connection "' . ($definition['name'] ?? '') . '"' . ($summary === '' ? '' : ' (' . $summary . ')');
    }

    public static function driverName(): ?string
    {
        return self::$definition['driver'] ?? null;
    }

    /** The open connection; opens it on first use. */
    public static function pdo(): \PDO
    {
        if (self::$pdo === null) {
            $started = hrtime(true);
            try {
                self::$pdo = self::connect();
            } finally {
                // Opened or not, this process never needs the password again.
                self::$password = null;
            }
            self::$connectMs = round((hrtime(true) - $started) / 1e6, 3);
        }

        return self::$pdo;
    }

    /**
     * Test Connection: opens the connection and reports the server's version, the current
     * database and user, and one round trip. Runs only Runlet's own fixed queries.
     *
     * @return array<string, mixed>
     */
    public static function test(): array
    {
        $pdo = self::pdo();
        $driver = self::driverName();
        $version = null;
        try {
            $version = (string) $pdo->getAttribute(\PDO::ATTR_SERVER_VERSION);
        } catch (\Throwable $error) {
            $version = null;
        }
        $started = hrtime(true);
        $pdo->query('SELECT 1')->fetchAll();
        $roundTrip = round((hrtime(true) - $started) / 1e6, 3);
        $database = null;
        $user = null;
        try {
            if ($driver === 'mysql') {
                $row = $pdo->query('SELECT DATABASE(), CURRENT_USER()')->fetch(\PDO::FETCH_NUM);
                [$database, $user] = is_array($row) ? $row : [null, null];
            } elseif ($driver === 'pgsql') {
                $row = $pdo->query('SELECT current_database(), current_user')->fetch(\PDO::FETCH_NUM);
                [$database, $user] = is_array($row) ? $row : [null, null];
            } elseif ($driver === 'sqlite') {
                $path = (string) (self::$definition['database'] ?? '');
                $real = $path === ':memory:' ? false : realpath($path);
                $database = $real === false ? $path : $real;
            }
        } catch (\Throwable $error) {
            // Version and round trip are enough; the names are a courtesy.
        }

        return array_filter([
            'driver' => $driver,
            'serverVersion' => $version,
            'database' => $database === null ? null : (string) $database,
            'user' => $user === null ? null : (string) $user,
            'connectMs' => self::$connectMs,
            'roundTripMs' => $roundTrip,
            'phpVersion' => PHP_VERSION,
        ], static function ($value): bool {
            return $value !== null;
        });
    }

    /**
     * Opens the connection. It takes no arguments, so neither the password nor the DSN is
     * ever in a stack frame; PDO's exception is replaced by one with its message only.
     */
    private static function connect(): \PDO
    {
        $definition = self::$definition;
        if ($definition === null) {
            throw new SqlConnectionFailed('No saved connection was sent with this run.');
        }
        $name = '"' . $definition['name'] . '"';
        $driver = $definition['driver'];
        if (!in_array($driver, self::DRIVERS, true)) {
            throw new SqlConnectionFailed('The saved connection ' . $name . ' uses the ' . $driver . ' driver, which this Runlet doesn\'t support.');
        }
        if (!class_exists('PDO', false)) {
            throw new SqlConnectionFailed('This target\'s PHP ' . PHP_VERSION . ' has no PDO extension, so it can\'t open the saved connection ' . $name . '.');
        }
        $available = \PDO::getAvailableDrivers();
        if (!in_array($driver, $available, true)) {
            throw new SqlConnectionFailed('This target\'s PHP ' . PHP_VERSION . ' has no pdo_' . $driver . ' driver. It has: ' . ($available === [] ? 'none' : implode(', ', $available)) . '.');
        }
        $dsn = self::dsn($definition);
        $options = [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION, \PDO::ATTR_TIMEOUT => $definition['timeout']];
        $warnings = [];
        set_error_handler(static function (int $severity, string $message) use (&$warnings): bool {
            $warnings[] = $message;

            return true;
        });
        $message = '';
        try {
            return new \PDO($dsn, $definition['user'] === '' ? null : $definition['user'], self::$password, $options);
        } catch (\Throwable $error) {
            $message = $error->getMessage();
        } finally {
            restore_error_handler();
        }
        if ($message === '' && $warnings !== []) {
            $message = implode(' ', $warnings);
        }
        // Thrown outside the catch, with no previous exception: nothing of PDO's trace stays.
        throw new SqlConnectionFailed(Channel::scrub('Runlet could not open the saved connection ' . $name . ' (' . $definition['summary'] . '): ' . $message));
    }

    /**
     * The PDO DSN. The app validates hosts and database names so they can't add DSN options;
     * this checks again.
     *
     * @param array{driver: string, host: string, port: int|null, database: string} $definition
     */
    private static function dsn(array $definition): string
    {
        $host = $definition['host'];
        $database = $definition['database'];
        if ($definition['driver'] === 'sqlite') {
            if ($database === '' || strpos($database, "\0") !== false) {
                throw new SqlConnectionFailed('The saved connection has no SQLite file.');
            }
            if ($database !== ':memory:' && !is_file($database)) {
                throw new SqlConnectionFailed('The SQLite file ' . $database . ' doesn\'t exist on this target' . (substr($database, 0, 1) === '/' ? '' : ' (a relative path starts in ' . (getcwd() ?: 'the project directory') . ')') . '. Runlet opens existing files only.');
            }

            return 'sqlite:' . $database;
        }
        if ($host === '' || preg_match('/^[A-Za-z0-9._:%\[\]-]+$/', $host) !== 1) {
            throw new SqlConnectionFailed('The saved connection\'s host "' . $host . '" isn\'t a host name or IP address.');
        }
        if (preg_match('/[;\'"\\\\\x00-\x1f]/', $database) === 1) {
            throw new SqlConnectionFailed('The saved connection\'s database name can\'t contain ";", quotes, or control characters.');
        }
        $port = (int) ($definition['port'] ?? ($definition['driver'] === 'pgsql' ? 5432 : 3306));
        if ($definition['driver'] === 'pgsql') {
            // libpq takes a bracket-less IPv6 address.
            $host = trim($host, '[]');

            return 'pgsql:host=' . $host . ';port=' . $port . ($database === '' ? '' : ";dbname='" . $database . "'");
        }

        return 'mysql:host=' . $host . ';port=' . $port . ($database === '' ? '' : ';dbname=' . $database) . ';charset=utf8mb4';
    }
}
