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
 * Read-only connections (#139): connect() makes the session read-only before anything else
 * runs (MySQL/MariaDB: SET SESSION TRANSACTION READ ONLY; PostgreSQL: SET SESSION
 * CHARACTERISTICS AS TRANSACTION READ ONLY; SQLite: the file opened read-only, and PRAGMA
 * query_only), checks that the database took it, and SqlTab sends the setting again before
 * each statement. SqlReadOnly refuses statements that would write or undo it, before the
 * connection is even opened; the app refuses them first.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class SqlConnect
{
    private const DRIVERS = ['mysql', 'pgsql', 'sqlite'];

    /** @var array{id: string, name: string, driver: string, host: string, port: int|null, database: string, user: string, timeout: int, summary: string, readOnly: bool}|null */
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
            'readOnly' => ($connection['readOnly'] ?? false) === true,
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

    /** The saved connection is read-only (#139). */
    public static function isReadOnly(): bool
    {
        return (self::$definition['readOnly'] ?? false) === true;
    }

    /**
     * Where results say they came from: `saved connection "Reporting" (pgsql, db:5432/reports)`,
     * with `, read-only session` for a read-only one (#139).
     */
    public static function origin(): string
    {
        $definition = self::$definition ?? [];
        $summary = (string) ($definition['summary'] ?? '');

        return 'saved connection "' . ($definition['name'] ?? '') . '"' . ($summary === '' ? '' : ' (' . $summary . ')') . (self::isReadOnly() ? ', read-only session' : '');
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
            // connect() checked that the database took the read-only setting.
            'readOnly' => self::isReadOnly() ? true : null,
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
        if ($driver === 'sqlite' && $definition['readOnly']) {
            // #139: SQLite opens the file read-only (PHP 7.3+), so no statement can write to it.
            $flags = self::constant(['Pdo\Sqlite::ATTR_OPEN_FLAGS', 'PDO::SQLITE_ATTR_OPEN_FLAGS']);
            $readOnly = self::constant(['Pdo\Sqlite::OPEN_READONLY', 'PDO::SQLITE_OPEN_READONLY']);
            if ($flags !== null && $readOnly !== null) {
                $options[$flags] = $readOnly;
            }
        }
        $warnings = [];
        set_error_handler(static function (int $severity, string $message) use (&$warnings): bool {
            $warnings[] = $message;

            return true;
        });
        $message = '';
        $pdo = null;
        try {
            $pdo = new \PDO($dsn, $definition['user'] === '' ? null : $definition['user'], self::$password, $options);
        } catch (\Throwable $error) {
            $message = $error->getMessage();
        } finally {
            restore_error_handler();
        }
        if ($pdo === null) {
            if ($message === '' && $warnings !== []) {
                $message = implode(' ', $warnings);
            }
            // Thrown outside the catch, with no previous exception: nothing of PDO's trace stays.
            throw new SqlConnectionFailed(Channel::scrub('Runlet could not open the saved connection ' . $name . ' (' . $definition['summary'] . '): ' . $message));
        }
        if ($definition['readOnly']) {
            $problem = self::makeReadOnly($pdo, $driver, true);
            if ($problem !== null) {
                $pdo = null;
                throw new SqlConnectionFailed(Channel::scrub('Runlet could not make the session of the read-only connection ' . $name . ' (' . $definition['summary'] . ') read-only, so nothing ran: ' . $problem));
            }
        }

        return $pdo;
    }

    /**
     * Read-only connections (#139): sends the driver's read-only setting again. SqlTab calls
     * it before each statement, so a statement that slipped past the refusals can't leave the
     * session writable for the next one. A failure stops the run.
     */
    public static function enforceReadOnly(): void
    {
        if (!self::isReadOnly() || self::$pdo === null) {
            return;
        }
        $problem = self::makeReadOnly(self::$pdo, (string) self::driverName(), false);
        if ($problem !== null) {
            throw new SqlConnectionFailed('Runlet could not keep the session of the read-only connection "' . self::name() . '" read-only, so it stopped: ' . $problem);
        }
    }

    /**
     * Sends the driver's read-only setting; with `$verify`, asks the database whether it took
     * it. Returns what went wrong, or null.
     */
    private static function makeReadOnly(\PDO $pdo, string $driver, bool $verify): ?string
    {
        $statements = [
            'mysql' => ['SET SESSION TRANSACTION READ ONLY', ['SELECT @@session.transaction_read_only', 'SELECT @@session.tx_read_only']],
            'pgsql' => ['SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY', ['SHOW default_transaction_read_only']],
            'sqlite' => ['PRAGMA query_only = ON', ['PRAGMA query_only']],
        ];
        if (!isset($statements[$driver])) {
            return 'the ' . $driver . ' driver has no read-only session.';
        }
        [$set, $checks] = $statements[$driver];
        try {
            $pdo->exec($set);
        } catch (\Throwable $error) {
            return $set . ' failed: ' . $error->getMessage() . ($driver === 'mysql' ? ' (MySQL 5.6.5 and MariaDB 10.0 or later have read-only sessions.)' : '');
        }
        if (!$verify) {
            return null;
        }
        $last = '';
        foreach ($checks as $check) {
            try {
                $statement = $pdo->query($check);
                $value = $statement === false ? false : $statement->fetchColumn();
                if ($statement !== false) {
                    $statement->closeCursor();
                }
            } catch (\Throwable $error) {
                // MySQL before 5.7.20 and MariaDB before 11.1 call it tx_read_only.
                $last = $error->getMessage();
                continue;
            }
            if (in_array(strtolower((string) $value), ['1', 'on', 'true'], true)) {
                return null;
            }

            return 'the database says the session is not read-only (' . $check . ' = ' . var_export($value, true) . ').';
        }

        return 'Runlet could not check it: ' . $last;
    }

    /**
     * The value of the first defined class or PDO constant (PHP 8.4 moved driver constants to
     * Pdo\Sqlite and deprecates the PDO:: ones later).
     *
     * @param string[] $names
     * @return int|null
     */
    private static function constant(array $names)
    {
        foreach ($names as $name) {
            if (defined($name)) {
                return (int) constant($name);
            }
        }

        return null;
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

/**
 * Read-only connections (#139): which statements the runner refuses to send, again after the
 * app (SQLReadOnly.swift holds the same rules). Refused: statements that would make the
 * session writable again (SET … TRANSACTION READ WRITE, SET transaction_read_only,
 * SET default_transaction_read_only, SET SESSION CHARACTERISTICS, BEGIN/START TRANSACTION
 * … READ WRITE, RESET ALL, DISCARD ALL, PRAGMA query_only, set_config()), anything that
 * doesn't start with a reading keyword (or plain transaction control), reads with a writing
 * keyword inside (a writable CTE, SELECT … INTO, FOR UPDATE, EXPLAIN ANALYZE of a write),
 * and a second statement after a `;`. The statement is read as each database could read it:
 * with and without backslash escapes, MySQL's executable comments opened, and `#` as a
 * comment (MySQL) or an operator (PostgreSQL, SQLite).
 */
final class SqlReadOnly
{
    private const READING = ['SELECT', 'SHOW', 'DESCRIBE', 'DESC', 'EXPLAIN', 'VALUES', 'TABLE', 'WITH', 'PRAGMA'];
    private const TRANSACTION = ['BEGIN', 'START', 'COMMIT', 'ROLLBACK', 'END', 'SAVEPOINT', 'RELEASE', 'ABORT'];
    private const SETTINGS = ['TRANSACTION_READ_ONLY', 'TX_READ_ONLY', 'DEFAULT_TRANSACTION_READ_ONLY', 'QUERY_ONLY'];
    private const EMBEDDED = ['INSERT', 'UPDATE', 'DELETE', 'MERGE', 'INTO', 'CREATE', 'DROP', 'ALTER', 'TRUNCATE'];
    private const WRITING = [
        'INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'MERGE', 'UPSERT', 'CREATE', 'ALTER', 'DROP', 'TRUNCATE', 'RENAME',
        'GRANT', 'REVOKE', 'COMMENT', 'LOCK', 'UNLOCK', 'CALL', 'EXEC', 'EXECUTE', 'DO', 'COPY', 'LOAD', 'IMPORT',
        'VACUUM', 'REINDEX', 'CLUSTER', 'REFRESH', 'ATTACH', 'DETACH', 'OPTIMIZE', 'REPAIR', 'ANALYZE', 'FLUSH',
        'PURGE', 'KILL', 'HANDLER', 'SET', 'RESET', 'SECURITY', 'INSTALL', 'UNINSTALL', 'SHUTDOWN',
    ];
    private const PRAGMA_READS = ['TABLE_INFO', 'TABLE_XINFO', 'TABLE_LIST', 'INDEX_INFO', 'INDEX_XINFO', 'INDEX_LIST', 'FOREIGN_KEY_LIST', 'FOREIGN_KEY_CHECK', 'INTEGRITY_CHECK', 'QUICK_CHECK'];

    /**
     * Why `$sql` isn't sent on a read-only connection ("can change data or the schema
     * (INSERT)"), or null when it may run.
     */
    public static function refusal(string $sql, ?string $driver): ?string
    {
        $backslash = strpos($sql, '\\') !== false;
        $readings = [];
        if ($driver === null || $driver === 'mysql') {
            $readings[] = [$sql, false, true];
            if ($backslash) {
                $readings[] = [$sql, true, true];
            }
            if (preg_match('~/\*M?!~', $sql) === 1) {
                $opened = (string) preg_replace('~/\*M?![0-9]*~', ' ', $sql);
                $readings[] = [$opened, false, true];
                $readings[] = [$opened, true, true];
            }
        }
        if ($driver !== 'mysql') {
            $readings[] = [$sql, false, false];
            if ($backslash && $driver !== 'sqlite') {
                $readings[] = [$sql, true, false];
            }
        }
        foreach ($readings as [$text, $escapes, $hashComments]) {
            $refusal = self::check(self::tokens($text, $escapes, $hashComments));
            if ($refusal !== null) {
                return $refusal;
            }
        }

        return null;
    }

    /** @param array<int, array{0: string, 1: string}> $tokens */
    private static function check(array $tokens): ?string
    {
        if ($tokens === []) {
            return null;
        }
        $semicolon = false;
        foreach ($tokens as [$kind]) {
            if ($kind === ';') {
                $semicolon = true;
            } elseif ($semicolon) {
                return 'holds several statements, and Runlet sends one at a time';
            }
        }
        // Words, and names that include quoted ones (`transaction_read_only`) for the settings.
        $words = [];
        $names = [];
        foreach ($tokens as [$kind, $text]) {
            if ($kind === 'w') {
                $words[] = $text;
                $names[] = ltrim($text, '@');
            } elseif ($kind === 'q') {
                $names[] = $text;
            }
        }
        if ($words === []) {
            return 'is one Runlet can\'t classify, so it can\'t tell whether it changes data';
        }
        $first = $words[0];
        $second = $words[1] ?? '';
        $change = static function (string $phrase): string {
            return 'would make the read-only session writable again (' . $phrase . ')';
        };
        if (in_array('SET_CONFIG', $names, true)) {
            return $change('set_config()');
        }
        foreach ($names as $name) {
            if (in_array($name, self::SETTINGS, true) && in_array($first, ['SET', 'RESET', 'PRAGMA', 'ALTER'], true)) {
                return $change($first . ' ' . strtolower($name));
            }
        }
        $readWrite = false;
        for ($index = 0; $index + 1 < count($tokens); $index++) {
            if ($tokens[$index][0] === 'w' && $tokens[$index][1] === 'READ' && $tokens[$index + 1][0] === 'w' && $tokens[$index + 1][1] === 'WRITE') {
                $readWrite = true;
            }
        }
        if ($first === 'SET' && (in_array('CHARACTERISTICS', $names, true) || $readWrite)) {
            return $change('SET … TRANSACTION READ WRITE');
        }
        if (in_array($first, ['BEGIN', 'START'], true) && $readWrite) {
            return $change($first . ' … READ WRITE');
        }
        if (in_array($first, ['RESET', 'DISCARD'], true) && $second === 'ALL') {
            return $change($first . ' ALL');
        }
        if (in_array($first, self::TRANSACTION, true) && ($first !== 'START' || $second === 'TRANSACTION')) {
            return null;
        }
        if (in_array($first, ['SET', 'RESET'], true)) {
            return 'changes the session\'s settings (' . $first . '), which could make it writable again';
        }
        if (in_array($first, self::WRITING, true)) {
            return 'can change data or the schema (' . $first . ')';
        }
        if (!in_array($first, self::READING, true)) {
            return 'starts with ' . $first . ', and Runlet can\'t tell whether it changes data';
        }
        if ($first === 'PRAGMA') {
            foreach ($tokens as $index => [$kind, $text]) {
                if ($kind === 'p' && $text === '=') {
                    return 'can change data or the schema (PRAGMA … =)';
                }
                if ($kind === 'p' && $text === '(') {
                    $name = '';
                    for ($before = $index - 1; $before >= 0; $before--) {
                        if ($tokens[$before][0] === 'w') {
                            $name = $tokens[$before][1];
                            break;
                        }
                    }

                    return in_array($name, self::PRAGMA_READS, true) ? null : 'can change data or the schema (PRAGMA … (…))';
                }
            }

            return null;
        }
        if ($first === 'EXPLAIN') {
            if (!in_array('ANALYZE', array_slice($words, 1, 3), true)) {
                return null;
            }
            foreach (array_slice($words, 1) as $name) {
                if (in_array($name, self::EMBEDDED, true) && $name !== 'INTO') {
                    return 'can change data or the schema (EXPLAIN ANALYZE … ' . $name . ')';
                }
            }

            return null;
        }
        foreach (array_slice($words, 1) as $position => $name) {
            if (in_array($name, self::EMBEDDED, true)) {
                $previous = $words[$position] ?? '';
                if ($name === 'UPDATE' && in_array($previous, ['FOR', 'KEY'], true)) {
                    return 'can change data or the schema (FOR UPDATE, which locks rows)';
                }

                return 'can change data or the schema (' . ($name === 'INTO' ? $first . ' … INTO' : $name) . ')';
            }
        }

        return null;
    }

    /**
     * The statement's tokens without comments: [kind, text], kind w (word, upper case), q
     * (quoted name, upper case), s (string), n (number), p (punctuation), or ;.
     *
     * @return array<int, array{0: string, 1: string}>
     */
    private static function tokens(string $sql, bool $escapes, bool $hashComments): array
    {
        $tokens = [];
        $length = strlen($sql);
        $i = 0;
        while ($i < $length) {
            $c = $sql[$i];
            $next = $i + 1 < $length ? $sql[$i + 1] : '';
            if (strpos(" \t\r\n\f", $c) !== false) {
                $i++;
                continue;
            }
            if (($c === '-' && $next === '-') || ($hashComments && $c === '#' && $next !== '>' && $next !== '-')) {
                $end = strpos($sql, "\n", $i);
                $i = $end === false ? $length : $end;
                continue;
            }
            if ($c === '/' && $next === '*') {
                $end = strpos($sql, '*/', $i + 2);
                $i = $end === false ? $length : $end + 2;
                continue;
            }
            if ($c === "'" || $c === '"' || $c === '`') {
                $j = $i + 1;
                while ($j < $length) {
                    if ($escapes && $c === "'" && $sql[$j] === '\\') {
                        $j += 2;
                        continue;
                    }
                    if ($sql[$j] === $c) {
                        if ($j + 1 < $length && $sql[$j + 1] === $c) {
                            $j += 2;
                            continue;
                        }
                        break;
                    }
                    $j++;
                }
                $tokens[] = [$c === "'" ? 's' : 'q', strtoupper(substr($sql, $i + 1, max(0, min($j, $length) - $i - 1)))];
                $i = $j + 1;
                continue;
            }
            if ($c === '$' && preg_match('/\G\$([A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*)?\$/', $sql, $match, 0, $i) === 1) {
                // A dollar-quoted body: $$…$$ or $tag$…$tag$.
                $end = strpos($sql, $match[0], $i + strlen($match[0]));
                $i = $end === false ? $length : $end + strlen($match[0]);
                $tokens[] = ['s', ''];
                continue;
            }
            if (preg_match('/\G[0-9]+[0-9A-Za-z.]*|\G\.[0-9][0-9A-Za-z.]*/', $sql, $match, 0, $i) === 1) {
                $tokens[] = ['n', $match[0]];
                $i += strlen($match[0]);
                continue;
            }
            if (preg_match('/\G[A-Za-z_\x80-\xff@][A-Za-z0-9_$@\x80-\xff]*/', $sql, $match, 0, $i) === 1) {
                $tokens[] = ['w', strtoupper($match[0])];
                $i += strlen($match[0]);
                continue;
            }
            $tokens[] = [$c === ';' ? ';' : 'p', $c];
            $i++;
        }

        return $tokens;
    }
}
