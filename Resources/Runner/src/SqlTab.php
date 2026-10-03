<?php

declare(strict_types=1);

/*
 * SQL tabs (#35): runs one statement from an SQL tab through the application's own database
 * connection and reports it as an `sql` event. The app generates the snippet that calls
 * SqlTab::run() (Packages/RunletKit/Sources/RunletCore/SQLTabs.swift); it never sends
 * credentials, and Runlet never asks for them.
 *
 * Where the connection comes from, in order:
 *  1. the booted driver's sqlConnection(): a project driver's own, or the built-in Laravel,
 *     Symfony (Doctrine), or WordPress ($wpdb) driver's;
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

final class SqlTab
{
    /** Columns kept per row; later columns are left out and counted. */
    private const MAX_COLUMNS = 200;
    /** Bytes kept of each text cell. */
    private const MAX_CELL_BYTES = 8192;
    /** Bytes of cells per result; rows past it are left out. */
    private const MAX_RESULT_BYTES = 8388608;
    /** Built-in drivers and how the tab names their connection's origin. */
    private const BUILTIN_SOURCES = [
        'Runlet\Drivers\LaravelDriver' => 'Laravel DB::connection()',
        'Runlet\Drivers\SymfonyDriver' => 'Symfony Doctrine registry',
        'Runlet\Drivers\WordPressDriver' => 'WordPress $wpdb',
    ];

    /** Runs `$sql` on the named (or default) connection and emits its `sql` event. */
    public static function run(string $sql, ?string $connection, int $maxRows): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        $maxRows = max(1, $maxRows);
        $names = self::connectionNames();
        [$source, $origin] = self::resolve($connection, $names);
        $started = hrtime(true);
        $result = $source instanceof \PDO ? self::runPdo($source, $sql, $maxRows) : self::runCallable($source, $sql, $maxRows);
        $result['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
        $result['connection'] = $connection;
        $result['source'] = $origin;
        $result['maxRows'] = $maxRows;
        if ($names !== []) {
            $result['connections'] = $names;
        }
        Channel::emit('sql', $result);

        return NoResult::instance();
    }

    /**
     * The connection to use and where it came from.
     *
     * @param string[] $names
     * @return array{0: \PDO|callable, 1: string}
     */
    private static function resolve(?string $connection, array $names): array
    {
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
        $name = $driver === null ? 'The project' : $driver->name();
        throw new SqlUnavailable($name . ' has no database connection that SQL tabs can use: its driver provides none, and the application set up no Eloquent connection or WordPress $wpdb. '
            . 'Runlet never asks for database credentials. To run SQL here, return a connection from sqlConnection() in a project driver (.runlet/<Name>Driver.php; see "SQL connections" in the drivers guide).');
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
        if ($driver === null) {
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
        $driverName = null;
        try {
            $driverName = (string) $pdo->getAttribute(\PDO::ATTR_DRIVER_NAME);
        } catch (\Throwable $error) {
            $driverName = null;
        }
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
