<?php

declare(strict_types=1);

/*
 * SQL tabs (#35): runs one statement from an SQL tab and reports it as an `sql` event. The
 * app generates the snippet that calls SqlTab::run() (Packages/RunletKit/Sources/RunletCore/
 * SQLTabs.swift); that code never holds credentials.
 *
 * Where the connection comes from, in order:
 *  0. a saved connection (#138), when the run carries one (SqlConnect.php): the user saved
 *     its definition for the target and its password in the Keychain; the request brings
 *     them on stdin, and the run booted no project code. A read-only one (#139) refuses
 *     writing and session-changing statements before connecting, and runs the rest in a
 *     read-only session;
 *  1. the booted driver's sqlConnection(): a project driver's own, or the built-in Laravel,
 *     Symfony (Doctrine), or WordPress ($wpdb) driver's. The application's own connections
 *     need no credentials from Runlet;
 *  2. an Eloquent connection resolver or WordPress's $wpdb that the application set up;
 *  3. otherwise an SqlUnavailable error that says so.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

/** The project has no database connection SQL tabs can use. */
final class SqlUnavailable extends \RuntimeException
{
}

/** The chosen connection could not be opened (an unknown name, a driver error, …). */
final class SqlConnectionFailed extends \RuntimeException
{
}

/**
 * A read-only saved connection (#139) refused a statement before anything was sent. The app
 * refuses it first; this is the runner's own check.
 */
final class SqlReadOnlyRefused extends \RuntimeException
{
}

/**
 * Run All Statements (#129): a statement failed, so the run stopped. The message says which
 * statement, what the transaction did, and which statements did not run.
 */
final class SqlStatementFailed extends \RuntimeException
{
}

final class SqlTab
{
    /** Columns kept per row; later columns are left out and counted. */
    private const MAX_COLUMNS = 200;
    /** Bytes kept of each text cell. */
    private const MAX_CELL_BYTES = 8192;
    /** Bytes of cells per result; rows past it are left out. */
    private const MAX_RESULT_BYTES = 8388608;
    /** Bytes of a statement's text echoed back with its result (Run All). */
    private const MAX_STATEMENT_ECHO_BYTES = 2000;
    /** Built-in drivers and how the tab names their connection's origin. */
    private const BUILTIN_SOURCES = [
        'Runlet\Drivers\LaravelDriver' => 'Laravel DB::connection()',
        'Runlet\Drivers\SymfonyDriver' => 'Symfony Doctrine registry',
        'Runlet\Drivers\WordPressDriver' => 'WordPress $wpdb',
    ];

    /**
     * Runs `$sql` on the named (or default) connection and emits its `sql` event. With
     * `$schema`, it then reads the connection's tables and columns for completion (#128), as
     * an `sqlSchema` event that never fails the run.
     */
    public static function run(string $sql, ?string $connection, int $maxRows, bool $schema = false): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        $maxRows = max(1, $maxRows);
        self::refuseOnReadOnly([['sql' => $sql, 'line' => 0]]);
        $names = self::connectionNames();
        [$source, $origin] = self::resolve($connection, $names);
        $started = hrtime(true);
        $result = $source instanceof \PDO ? self::runPdo($source, $sql, $maxRows) : self::runCallable($source, $sql, $maxRows);
        $result['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
        $result['source'] = $origin;
        $result['maxRows'] = $maxRows;
        $result += self::connectionFields($connection);
        if ($names !== []) {
            $result['connections'] = $names;
        }
        Channel::emit('sql', $result);
        if ($schema) {
            self::emitSchema($connection, $source, $origin, $result['driver'] ?? null);
        }

        return NoResult::instance();
    }

    /**
     * Test Connection (#138): opens the run's saved connection and emits an `sqlTest` event
     * (server version, current database and user, round trip). No statement of the user's.
     */
    public static function test(): NoResult
    {
        if (!SqlConnect::isConfigured()) {
            throw new SqlUnavailable('Test Connection needs a saved connection, and this run has none.');
        }
        Channel::emit('sqlTest', SqlConnect::test());

        return NoResult::instance();
    }

    /**
     * The `connection` of a result: the tab's application connection name (null for the
     * default), or a saved connection's name with `saved` (#138).
     *
     * @return array<string, mixed>
     */
    private static function connectionFields(?string $connection): array
    {
        return SqlConnect::isConfigured() ? ['connection' => SqlConnect::name(), 'saved' => true] : ['connection' => $connection];
    }

    /**
     * Schema (#128): emits the connection's tables and columns as an `sqlSchema` event. Only
     * names and types are read, never rows. Loading the schema is explicit (the SQL bar's
     * Load Schema) or follows a statement that ran.
     */
    public static function schema(?string $connection): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        [$source, $origin] = self::resolve($connection, self::connectionNames());
        self::emitSchema($connection, $source, $origin, $source instanceof \PDO ? self::pdoDriverName($source) : null, true);

        return NoResult::instance();
    }

    /**
     * @param \PDO|callable $source
     */
    private static function emitSchema(?string $connection, $source, string $origin, ?string $driverName, bool $throw = false): void
    {
        $started = hrtime(true);
        $payload = ['driver' => $driverName, 'source' => $origin] + self::connectionFields($connection);
        try {
            $read = SqlSchema::read($connection, $source, $origin, $driverName);
            $payload = array_merge($payload, $read);
        } catch (DriverFailure $failure) {
            if ($throw) {
                throw $failure;
            }
            $payload['error'] = $failure->getMessage();
        } catch (\Throwable $error) {
            if ($throw) {
                throw new SqlConnectionFailed('Runlet could not read the schema: ' . $error->getMessage(), 0, $error);
            }
            $payload['error'] = 'Runlet could not read the schema: ' . $error->getMessage();
        }
        $payload['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
        Channel::emit('sqlSchema', array_filter($payload, static function ($value): bool {
            return $value !== null;
        }));
    }

    /**
     * Run All Statements (#129): runs `$statements` in order on one connection and emits an
     * `sql` event per statement (with `statement`: index, count, line, and text). Stops at the
     * first error. With `$transaction`, the run is one transaction: committed after the last
     * statement, rolled back when one fails. MySQL and MariaDB commit some statements at once
     * (CREATE, ALTER, DROP, … flagged `implicitCommit` by the app): Runlet says so before
     * running and opens a new transaction after each of them, so a later failure rolls back
     * only what came after.
     *
     * With `$schema`, the connection's tables and columns follow when every statement ran (#128).
     *
     * @param array<int, array{sql: string, line: int, implicitCommit?: bool}> $statements
     */
    public static function runAll(array $statements, ?string $connection, int $maxRows, bool $transaction, bool $schema = false): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        $maxRows = max(1, $maxRows);
        $statements = array_values($statements);
        $count = count($statements);
        if ($count === 0) {
            throw new \InvalidArgumentException('There are no statements to run.');
        }
        self::refuseOnReadOnly($statements);
        $names = self::connectionNames();
        [$source, $origin] = self::resolve($connection, $names);
        $driverName = $source instanceof \PDO ? self::pdoDriverName($source) : ($origin === 'WordPress $wpdb' ? 'mysql' : null);
        $commitsAtOnce = $transaction && in_array($driverName, ['mysql', 'oci'], true);
        if ($commitsAtOnce) {
            $flagged = [];
            foreach ($statements as $index => $statement) {
                if (!empty($statement['implicitCommit'])) {
                    $flagged[] = ($index + 1) . ' (line ' . (int) $statement['line'] . ')';
                }
            }
            if ($flagged !== []) {
                Channel::emit('notice', ['message' => ($driverName === 'oci' ? 'Oracle' : 'MySQL') . ' commits ' . (count($flagged) === 1 ? 'statement ' : 'statements ') . self::listing($flagged)
                    . ' at once, with everything before ' . (count($flagged) === 1 ? 'it' : 'them') . ', even in a transaction. If a later statement fails, only the statements after the last of them are rolled back.']);
            }
        }
        if ($transaction) {
            try {
                self::begin($source);
            } catch (DriverFailure $failure) {
                throw $failure;
            } catch (\Throwable $error) {
                throw new SqlConnectionFailed('Runlet could not start a transaction on this connection: ' . $error->getMessage() . ' Nothing ran. To run the statements without one, turn off "In a Transaction" in the SQL bar.', 0, $error);
            }
        }
        $committedThrough = 0;
        foreach ($statements as $index => $statement) {
            $sql = (string) $statement['sql'];
            $line = (int) $statement['line'];
            $started = hrtime(true);
            try {
                if ($index > 0) {
                    // #139: whatever the statement before did, the next one runs read-only.
                    SqlConnect::enforceReadOnly();
                }
                $result = $source instanceof \PDO ? self::runPdo($source, $sql, $maxRows) : self::runCallable($source, $sql, $maxRows);
            } catch (DriverFailure $failure) {
                throw $failure;
            } catch (\Throwable $error) {
                $notes = [];
                if ($transaction) {
                    $notes[] = self::rollBack($source, $index, $committedThrough);
                }
                if ($index + 1 < $count) {
                    $notes[] = ($index + 2 === $count ? 'Statement ' . $count . ' did' : 'Statements ' . ($index + 2) . '–' . $count . ' did') . ' not run.';
                }
                throw new SqlStatementFailed('Statement ' . ($index + 1) . ' of ' . $count . ' (line ' . $line . '): ' . $error->getMessage() . "\n\n" . implode(' ', $notes), 0, $error);
            }
            $result['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
            $result['source'] = $origin;
            $result['maxRows'] = $maxRows;
            $result += self::connectionFields($connection);
            if ($index === 0 && $names !== []) {
                $result['connections'] = $names;
            }
            $result['statement'] = ['index' => $index + 1, 'count' => $count, 'line' => $line, 'text' => self::echoed($sql)];
            Channel::emit('sql', $result);
            if ($commitsAtOnce && !empty($statement['implicitCommit'])) {
                // The database ended the transaction; the rest of the run gets a new one.
                $committedThrough = $index + 1;
                self::endImplicitlyCommitted($source);
                self::begin($source);
            }
        }
        if ($transaction) {
            try {
                self::commit($source);
            } catch (DriverFailure $failure) {
                throw $failure;
            } catch (\Throwable $error) {
                throw new SqlStatementFailed('All ' . $count . ' statements ran, but Runlet could not commit the transaction: ' . $error->getMessage() . ' The database has probably rolled it back.', 0, $error);
            }
            Channel::emit('notice', ['message' => 'Committed the transaction: ' . ($count === 1 ? 'the statement ran' : 'all ' . $count . ' statements ran') . '.']);
        }
        if ($schema) {
            self::emitSchema($connection, $source, $origin, $driverName);
        }

        return NoResult::instance();
    }

    /**
     * Read-only saved connections (#139): refuses the whole run, before the connection is
     * opened, when any statement would write or make the session writable again.
     *
     * @param array<int, array{sql: string, line: int}> $statements
     */
    private static function refuseOnReadOnly(array $statements): void
    {
        if (!SqlConnect::isConfigured() || !SqlConnect::isReadOnly()) {
            return;
        }
        $count = count($statements);
        foreach (array_values($statements) as $index => $statement) {
            $why = SqlReadOnly::refusal((string) $statement['sql'], SqlConnect::driverName());
            if ($why === null) {
                continue;
            }
            $name = '"' . SqlConnect::name() . '"';
            throw new SqlReadOnlyRefused($count === 1
                ? 'Runlet refused this statement on the read-only connection ' . $name . ': it ' . $why . '. Nothing ran.'
                : 'Statement ' . ($index + 1) . ' of ' . $count . ' (line ' . (int) $statement['line'] . ') ' . $why . ', so Runlet ran none of the script on the read-only connection ' . $name . '. Nothing ran.');
        }
    }

    /** @param callable|\PDO $source */
    private static function begin($source): void
    {
        if ($source instanceof \PDO) {
            $source->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
            $source->beginTransaction();

            return;
        }
        $source('BEGIN');
    }

    /** @param callable|\PDO $source */
    private static function commit($source): void
    {
        if ($source instanceof \PDO) {
            if ($source->inTransaction()) {
                $source->commit();
            }

            return;
        }
        $source('COMMIT');
    }

    /**
     * After a statement the database committed at once: PHP 8 already sees no transaction;
     * PHP 7.4 still thinks one is open, and COMMIT ends it without changing anything.
     *
     * @param callable|\PDO $source
     */
    private static function endImplicitlyCommitted($source): void
    {
        try {
            if ($source instanceof \PDO) {
                if ($source->inTransaction()) {
                    $source->commit();
                }
            } else {
                // MySQL ignores a COMMIT without a transaction; elsewhere (WordPress on
                // SQLite, …) it commits here, as MySQL did.
                $source('COMMIT');
            }
        } catch (\Throwable $error) {
            // Nothing was open any more.
        }
    }

    /**
     * Rolls back after statement `$failed` (0-based) failed and says what that undid.
     *
     * @param callable|\PDO $source
     */
    private static function rollBack($source, int $failed, int $committedThrough): string
    {
        try {
            if ($source instanceof \PDO) {
                if ($source->inTransaction()) {
                    $source->rollBack();
                }
            } else {
                $source('ROLLBACK');
            }
        } catch (\Throwable $error) {
            return 'Runlet could not roll back the transaction: ' . $error->getMessage() . ($failed > 0 ? ' Check what ' . ($failed === 1 ? 'statement 1' : 'statements 1–' . $failed) . ' changed.' : '');
        }
        $first = $committedThrough + 1;
        $undone = $failed < $first ? 'Rolled back the transaction.' : 'Rolled back the transaction: ' . ($failed === $first ? 'statement ' . $first . ' was' : 'statements ' . $first . '–' . $failed . ' were') . ' undone.';
        if ($committedThrough > 0) {
            $undone .= ' ' . ($committedThrough === 1 ? 'Statement 1 stays' : 'Statements 1–' . $committedThrough . ' stay') . ': the database committed ' . ($committedThrough === 1 ? 'it' : 'them') . ' at statement ' . $committedThrough . '.';
        }

        return $undone;
    }

    /** @param string[] $items "1, 2 and 3" */
    private static function listing(array $items): string
    {
        if (count($items) < 2) {
            return implode('', $items);
        }

        return implode(', ', array_slice($items, 0, -1)) . ' and ' . $items[count($items) - 1];
    }

    /** A statement's text for its result card, cut at a UTF-8 boundary. */
    private static function echoed(string $sql): string
    {
        $sql = trim($sql);
        if (strlen($sql) <= self::MAX_STATEMENT_ECHO_BYTES) {
            return $sql;
        }
        $cut = substr($sql, 0, self::MAX_STATEMENT_ECHO_BYTES);
        while ($cut !== '' && preg_match('//u', $cut) !== 1) {
            $cut = substr($cut, 0, -1);
        }

        return $cut . '…';
    }

    private static function pdoDriverName(\PDO $pdo): ?string
    {
        try {
            return (string) $pdo->getAttribute(\PDO::ATTR_DRIVER_NAME);
        } catch (\Throwable $error) {
            return null;
        }
    }

    /**
     * The connection to use and where it came from.
     *
     * @param string[] $names
     * @return array{0: \PDO|callable, 1: string}
     */
    private static function resolve(?string $connection, array $names): array
    {
        if (SqlConnect::isConfigured()) {
            // A saved connection (#138): opened here, in a process that booted no project code.
            return [SqlConnect::pdo(), SqlConnect::origin()];
        }
        $driver = Runner::bootedDriver();
        $known = $names === [] ? '' : ' Connections: ' . implode(', ', $names) . '.';
        try {
            if ($driver !== null) {
                $source = Runner::callBootedDriver('sqlConnection()', static function () use ($driver, $connection) {
                    return $driver->sqlConnection($connection);
                });
                if ($source !== null) {
                    $declaring = (new \ReflectionMethod($driver, 'sqlConnection'))->getDeclaringClass()->getName();
                    if (!$source instanceof \PDO && !is_callable($source)) {
                        throw new \UnexpectedValueException($declaring . '::sqlConnection() returned ' . (is_object($source) ? get_class($source) : gettype($source)) . '; return a PDO, a callable, or null.');
                    }

                    return [$source, self::BUILTIN_SOURCES[$declaring] ?? $declaring . '::sqlConnection()'];
                }
            }
            $detected = self::detect($connection);
        } catch (DriverFailure $failure) {
            throw $failure;
        } catch (\Throwable $error) {
            $what = $connection === null ? 'the default connection' : 'the "' . $connection . '" connection';
            throw new SqlConnectionFailed('Runlet could not open ' . $what . ': ' . $error->getMessage() . $known, 0, $error);
        }
        if ($detected !== null) {
            return $detected;
        }
        $name = $driver === null ? 'none' : $driver->name();
        throw new SqlUnavailable('This project has no database connection that SQL tabs can use. Its driver (' . $name . ') provides none, and the application set up no Eloquent connection or WordPress $wpdb. '
            . 'To run SQL here, save a connection for this target (New Connection… in the SQL bar\'s connection menu; its password goes to the Keychain), or return one from sqlConnection() in a project driver (.runlet/<Name>Driver.php; see "SQL connections" in the drivers guide).');
    }

    /**
     * A connection the application set up without its driver saying so: Eloquent's
     * connection resolver (Laravel, or illuminate/database through Capsule) or $wpdb. Only
     * classes that are already loaded count; nothing is autoloaded to find out.
     *
     * @return array{0: \PDO|callable, 1: string}|null
     */
    private static function detect(?string $connection): ?array
    {
        $model = 'Illuminate\Database\Eloquent\Model';
        if (class_exists($model, false) && method_exists($model, 'getConnectionResolver')) {
            $resolver = $model::getConnectionResolver();
            if (is_object($resolver)) {
                return [\Runlet\SqlConnections::eloquent($resolver, $connection), 'Eloquent connection resolver'];
            }
        }
        $wpdb = $GLOBALS['wpdb'] ?? null;
        if (is_object($wpdb) && class_exists('wpdb', false) && $wpdb instanceof \wpdb) {
            if ($connection !== null) {
                throw new \InvalidArgumentException('WordPress has one database connection ($wpdb), not "' . $connection . '".');
            }

            return [\Runlet\SqlConnections::wpdb($wpdb), 'WordPress $wpdb'];
        }

        return null;
    }

    /** @return string[] The driver's connection names (default first), cleaned; [] when it lists none. */
    private static function connectionNames(): array
    {
        $driver = Runner::bootedDriver();
        if ($driver === null || SqlConnect::isConfigured()) {
            return [];
        }
        try {
            $names = Runner::callBootedDriver('sqlConnections()', static function () use ($driver): array {
                return $driver->sqlConnections();
            });
        } catch (\Throwable $error) {
            Channel::emit('notice', ['message' => 'The connection list is unavailable: ' . $error->getMessage()]);

            return [];
        }
        $clean = [];
        foreach ($names as $name) {
            if ((is_string($name) || is_int($name)) && (string) $name !== '' && strlen((string) $name) <= 200 && !in_array((string) $name, $clean, true)) {
                $clean[] = (string) $name;
            }
        }

        return array_slice($clean, 0, 100);
    }

    /** @return array<string, mixed> */
    private static function runPdo(\PDO $pdo, string $sql, int $maxRows): array
    {
        $driverName = self::pdoDriverName($pdo);
        $restore = [\PDO::ATTR_ERRMODE => $pdo->getAttribute(\PDO::ATTR_ERRMODE)];
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        if ($driverName === 'mysql') {
            // Native prepares, so MySQL refuses several statements in one run; unbuffered, so
            // a large result is not held in memory beyond the rows Runlet keeps.
            $buffered = defined('Pdo\Mysql::ATTR_USE_BUFFERED_QUERY') ? constant('Pdo\Mysql::ATTR_USE_BUFFERED_QUERY') : (defined('PDO::MYSQL_ATTR_USE_BUFFERED_QUERY') ? constant('PDO::MYSQL_ATTR_USE_BUFFERED_QUERY') : null);
            foreach ([\PDO::ATTR_EMULATE_PREPARES => false, $buffered => false] as $attribute => $value) {
                if ($attribute === null || $attribute === '') {
                    continue;
                }
                try {
                    $previous = $pdo->getAttribute((int) $attribute);
                    if ($pdo->setAttribute((int) $attribute, $value)) {
                        $restore[(int) $attribute] = $previous;
                    }
                } catch (\Throwable $error) {
                    // The attribute isn't supported here: keep the connection's setting.
                }
            }
        }
        try {
            $statement = $pdo->prepare($sql);
            $statement->execute();
            $count = $statement->columnCount();
            if ($count <= 0) {
                return ['driver' => $driverName, 'affectedRows' => $statement->rowCount()];
            }
            $columns = [];
            for ($index = 0; $index < min($count, self::MAX_COLUMNS); $index++) {
                $meta = false;
                try {
                    $meta = $statement->getColumnMeta($index);
                } catch (\Throwable $error) {
                    $meta = false;
                }
                $columns[] = is_array($meta) && isset($meta['name']) && $meta['name'] !== '' ? (string) $meta['name'] : 'column ' . ($index + 1);
            }
            $rows = [];
            $bytes = 0;
            $truncation = null;
            while (($row = $statement->fetch(\PDO::FETCH_NUM)) !== false) {
                if (count($rows) >= $maxRows) {
                    $truncation = 'rows';
                    break;
                }
                if ($bytes >= self::MAX_RESULT_BYTES) {
                    $truncation = 'bytes';
                    break;
                }
                $cells = [];
                foreach (array_slice($row, 0, count($columns)) as $value) {
                    $cells[] = self::cell($value, $bytes);
                }
                $rows[] = $cells;
            }
            $statement->closeCursor();

            return array_filter([
                'driver' => $driverName,
                'columns' => $columns,
                'rows' => $rows,
                'truncated' => $truncation !== null ? true : null,
                'truncation' => $truncation,
                'omittedColumns' => $count > count($columns) ? $count - count($columns) : null,
            ], static function ($value): bool {
                return $value !== null;
            });
        } finally {
            foreach ($restore as $attribute => $value) {
                try {
                    $pdo->setAttribute($attribute, $value);
                } catch (\Throwable $error) {
                    // Best effort: the run ends right after this anyway.
                }
            }
        }
    }

    /** @return array<string, mixed> */
    private static function runCallable(callable $run, string $sql, int $maxRows): array
    {
        $returned = $run($sql);
        if (is_int($returned)) {
            return ['affectedRows' => $returned];
        }
        if (!is_iterable($returned)) {
            throw new \UnexpectedValueException('The SQL connection callable returned ' . (is_object($returned) ? get_class($returned) : gettype($returned)) . '; return the rows (an iterable of arrays or objects) or the number of affected rows (an int).');
        }
        $columns = [];
        $positions = [];
        $omitted = [];
        $records = [];
        $bytes = 0;
        $truncation = null;
        foreach ($returned as $row) {
            if (count($records) >= $maxRows) {
                $truncation = 'rows';
                break;
            }
            if ($bytes >= self::MAX_RESULT_BYTES) {
                $truncation = 'bytes';
                break;
            }
            $fields = is_object($row) ? get_object_vars($row) : (is_array($row) ? $row : ['value' => $row]);
            $cells = [];
            foreach ($fields as $key => $value) {
                $key = (string) $key;
                if (!isset($positions[$key])) {
                    if (count($columns) >= self::MAX_COLUMNS) {
                        $omitted[$key] = true;
                        continue;
                    }
                    $positions[$key] = count($columns);
                    $columns[] = $key;
                }
                $cells[$positions[$key]] = self::cell($value, $bytes);
            }
            $records[] = $cells;
        }
        $rows = [];
        foreach ($records as $cells) {
            $row = [];
            for ($index = 0; $index < count($columns); $index++) {
                $row[] = array_key_exists($index, $cells) ? $cells[$index] : null;
            }
            $rows[] = $row;
        }

        return array_filter([
            'columns' => $columns,
            'rows' => $rows,
            'truncated' => $truncation !== null ? true : null,
            'truncation' => $truncation,
            'omittedColumns' => $omitted === [] ? null : count($omitted),
        ], static function ($value): bool {
            return $value !== null;
        });
    }

    /**
     * One cell as JSON: null, a bool, a number, or text; an object for text Runlet shortened
     * (`text`, `omittedBytes`; -1 when the full size is unknown) or bytes that aren't UTF-8
     * (`binary` byte count, `hex` of the first 32 bytes).
     *
     * @param mixed $value
     * @return mixed
     */
    private static function cell($value, int &$bytes)
    {
        if ($value === null || is_bool($value) || is_int($value)) {
            $bytes += 8;

            return $value;
        }
        if (is_float($value)) {
            $bytes += 16;

            return is_finite($value) ? $value : (string) $value;
        }
        $unknownLength = false;
        if (is_resource($value)) {
            // Large objects (PostgreSQL bytea, Oracle LOBs) arrive as streams.
            $read = @stream_get_contents($value, self::MAX_CELL_BYTES + 1);
            $value = $read === false ? '' : $read;
            $unknownLength = strlen($value) > self::MAX_CELL_BYTES;
        } elseif ($value instanceof \DateTimeInterface) {
            $value = $value->format('Y-m-d H:i:s.uP');
        } elseif (is_object($value)) {
            $value = method_exists($value, '__toString') ? (string) $value : get_class($value);
        } elseif (is_array($value)) {
            $encoded = json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR);
            $value = $encoded === false ? 'array' : $encoded;
        }
        $string = (string) $value;
        $length = strlen($string);
        if (preg_match('//u', $string) !== 1) {
            $bytes += 80;

            return ['binary' => $unknownLength ? -1 : $length, 'hex' => strtoupper(bin2hex(substr($string, 0, 32)))];
        }
        if ($length > self::MAX_CELL_BYTES) {
            $cut = substr($string, 0, self::MAX_CELL_BYTES);
            while ($cut !== '' && preg_match('//u', $cut) !== 1) {
                $cut = substr($cut, 0, -1);
            }
            $bytes += strlen($cut);

            return ['text' => $cut, 'omittedBytes' => $unknownLength ? -1 : $length - strlen($cut)];
        }
        $bytes += $length;

        return $string;
    }
}
