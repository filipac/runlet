<?php

declare(strict_types=1);

/*
 * Explain Statement in SQL tabs (#147). SqlTab::explain() resolves the tab's connection (the
 * application's, or a saved one) and hands it here with the statement. Runlet puts the
 * database's own EXPLAIN in front of the statement and sends that alone; the app reads the
 * answer into a plan tree (Packages/RunletKit/Sources/RunletCore/SQLPlan.swift).
 *
 *  - Explain (plan only) never runs the statement: MySQL and MariaDB `EXPLAIN FORMAT=JSON`,
 *    PostgreSQL `EXPLAIN (FORMAT JSON)`, SQLite `EXPLAIN QUERY PLAN`.
 *  - Explain Analyze runs it: MariaDB `ANALYZE FORMAT=JSON`, MySQL 8.0.18+ `EXPLAIN ANALYZE`
 *    (a text tree), PostgreSQL `EXPLAIN (ANALYZE, FORMAT JSON)` in a transaction that is
 *    always rolled back. A statement that can write (or that Runlet can't classify) is refused
 *    on MySQL and MariaDB, where DDL and non-transactional tables can't be rolled back, and on
 *    read-only saved connections (#139). SQLite has no EXPLAIN ANALYZE.
 *  - SQL Server, other PDO drivers, and callables whose database Runlet doesn't know are
 *    refused with a message. WordPress's $wpdb is MySQL.
 *
 * The statement is prepared natively (no emulation), so the database refuses a second
 * statement after a `;` instead of running it. Bound values (#145) are bound by SqlTab, as
 * for run(), which also refuses them on callables.
 *
 * The run inspector's Explain tab (#4, #170) runs its EXPLAIN itself, through the captured
 * connection, and hands the rows to Runlet\explainPlan() (at the end of this file), which
 * reads them into the same `sqlPlan` event (SqlExplain::fromRows()).
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

/** Explain Statement can't explain on this connection, or refused Explain Analyze. Nothing ran. */
final class SqlExplainRefused extends \RuntimeException
{
}

final class SqlExplain
{
    /** Bytes of the database's own output kept. */
    private const MAX_RAW_BYTES = 4194304;
    /** SQLite's EXPLAIN QUERY PLAN rows kept. */
    private const MAX_ROWS = 10000;

    /**
     * Refusals that need no connection: a statement that is already an EXPLAIN, and Explain
     * Analyze of a write on a read-only saved connection.
     */
    public static function refuseEarly(string $sql, bool $analyze): void
    {
        $first = self::firstWord($sql);
        if (in_array($first, ['EXPLAIN', 'DESCRIBE', 'DESC', 'ANALYZE'], true)) {
            throw new SqlExplainRefused('This statement already starts with ' . $first . '. Explain Statement adds the database\'s own EXPLAIN: remove ' . $first . ', or run the statement as written. Nothing ran.');
        }
        if ($analyze && SqlConnect::isConfigured() && SqlConnect::isReadOnly()) {
            $why = SqlReadOnly::refusal($sql, SqlConnect::driverName());
            if ($why !== null) {
                throw new SqlReadOnlyRefused('Explain Analyze runs the statement, and Runlet refused it on the read-only connection "' . SqlConnect::name() . '": it ' . $why . '. Explain Statement (without Analyze) shows its plan without running it. Nothing ran.');
            }
        }
    }

    /**
     * Explains `$sql` on `$source` and returns the `sqlPlan` event's payload (without the
     * connection fields SqlTab adds).
     *
     * @param \PDO|callable $source
     * @param callable(\PDOStatement): void|null $bind Binds the statement's values (#145).
     * @return array<string, mixed>
     */
    public static function explain($source, string $origin, ?string $driverName, string $sql, bool $analyze, ?callable $bind = null): array
    {
        $serverVersion = $source instanceof \PDO ? self::serverVersion($source) : null;
        $dialect = self::dialect($source, $origin, $driverName, $serverVersion);
        if ($analyze) {
            self::refuseAnalyze($dialect, $sql);
        }
        [$prefix, $format] = self::prefix($dialect, $analyze);
        $explained = $prefix . ' ' . self::withoutTrailingSemicolon($sql);
        $payload = [
            'driver' => $dialect === 'mariadb' ? 'mysql' : $dialect,
            'dialect' => $dialect,
            'format' => $format,
            'analyze' => $analyze,
            'explained' => $prefix,
            'serverVersion' => $serverVersion,
        ];
        $rolledBack = false;
        if ($source instanceof \PDO) {
            $transaction = $analyze && $dialect === 'pgsql';
            if ($transaction) {
                // PostgreSQL: Explain Analyze runs the statement in a transaction that is always
                // rolled back, so a write it makes doesn't stay.
                $source->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
                $source->beginTransaction();
            }
            try {
                $rows = self::fetchPdo($source, $dialect, $explained, $bind);
            } catch (\PDOException $error) {
                if (($dialect === 'mysql' || $dialect === 'mariadb') && SqlConnect::isConfigured() && SqlConnect::isReadOnly() && strpos($error->getMessage(), '1792') !== false) {
                    // #139: MySQL and MariaDB won't even explain a write in a read-only session.
                    throw new SqlExplainRefused(($dialect === 'mariadb' ? 'MariaDB' : 'MySQL') . ' refuses to explain a statement that writes in a read-only session (error 1792), although EXPLAIN wouldn\'t run it. Explain it on a connection that isn\'t read-only, or explain the SELECT that finds the same rows. Nothing ran.', 0, $error);
                }
                throw $error;
            } finally {
                if ($transaction) {
                    try {
                        if ($source->inTransaction()) {
                            $source->rollBack();
                        }
                        $rolledBack = true;
                    } catch (\Throwable $error) {
                        // The connection is gone with the run; nothing was committed.
                        $rolledBack = true;
                    }
                }
            }
        } else {
            $rows = self::fetchCallable($source, $explained);
        }
        if ($dialect === 'sqlite') {
            $payload['rows'] = self::planRows($rows);
        } else {
            $payload += self::raw(self::rawText($rows, $dialect));
        }
        if ($rolledBack) {
            $payload['rolledBack'] = true;
        }

        return self::withoutNulls($payload);
    }

    /**
     * The run inspector's Explain tab (#170): `Runlet\explainPlan()` hands over the EXPLAIN
     * rows the tab's own code fetched, and this returns them as the `sqlPlan` event's payload,
     * or null when they aren't a plan Runlet reads (MySQL's tabular EXPLAIN, PostgreSQL's text
     * plan, a database it doesn't know), which the tab then shows as rows. It sends nothing
     * to the database: the dialect and server version come from the connection object.
     *
     * @param mixed $rows
     * @param mixed $connection a PDO, an Illuminate or Doctrine DBAL connection, $wpdb, a
     *        dialect name (`mysql`, `mariadb`, `pgsql`, `sqlite`), or null to tell by the rows
     * @return array<string, mixed>|null
     */
    public static function fromRows($rows, $connection, ?string $connectionName): ?array
    {
        $rows = self::rowList($rows);
        if ($rows === null || $rows === []) {
            return null;
        }
        [$dialect, $serverVersion, $source, $name] = self::describe($connection);
        $first = $rows[0];
        if ($dialect === null) {
            // Each database names its EXPLAIN's column: SQLite `detail`, PostgreSQL
            // `QUERY PLAN`, MySQL and MariaDB `EXPLAIN`.
            $dialect = array_key_exists('detail', $first) ? 'sqlite' : (array_key_exists('QUERY PLAN', $first) ? 'pgsql' : (array_key_exists('EXPLAIN', $first) ? 'mysql' : null));
            if ($dialect === null) {
                return null;
            }
        }
        $payload = [
            'driver' => $dialect === 'mariadb' ? 'mysql' : $dialect,
            'dialect' => $dialect,
            'analyze' => false,
            'serverVersion' => $serverVersion,
            'connection' => $connectionName ?? $name,
            'source' => $source,
        ];
        if ($dialect === 'sqlite') {
            if (!array_key_exists('detail', $first)) {
                return null;
            }
            $payload['format'] = 'rows';
            $payload['explained'] = 'EXPLAIN QUERY PLAN';
            $payload['rows'] = self::planRows($rows);

            return self::withoutNulls($payload);
        }
        if (count($first) !== 1) {
            return null;
        }
        $raw = ltrim(self::rawText($rows, $dialect));
        if ($dialect === 'pgsql') {
            if ($raw === '' || ($raw[0] !== '[' && $raw[0] !== '{')) {
                return null;
            }
            $payload['format'] = 'json';
            $payload['explained'] = 'EXPLAIN (FORMAT JSON)';
            // The parser reads the actual figures of an ANALYZE the user wrote in.
            $payload['analyze'] = strpos($raw, '"Execution Time"') !== false;
        } elseif ($raw !== '' && $raw[0] === '{') {
            $payload['format'] = 'json';
            $payload['explained'] = 'EXPLAIN FORMAT=JSON';
            $payload['analyze'] = $dialect === 'mariadb' && strpos($raw, '"r_loops"') !== false;
        } elseif (strncmp($raw, '->', 2) === 0) {
            // MySQL's EXPLAIN FORMAT=TREE, or the EXPLAIN ANALYZE the user wrote in.
            $payload['format'] = 'tree';
            $payload['analyze'] = strpos($raw, '(actual time=') !== false;
            $payload['explained'] = $payload['analyze'] ? 'EXPLAIN ANALYZE' : 'EXPLAIN FORMAT=TREE';
        } else {
            return null;
        }
        $payload += self::raw($raw);

        return self::withoutNulls($payload);
    }

    /**
     * The database's output, at most MAX_RAW_BYTES of it, as valid UTF-8.
     *
     * @return array<string, mixed>
     */
    private static function raw(string $raw): array
    {
        $payload = [];
        if (strlen($raw) > self::MAX_RAW_BYTES) {
            $raw = substr($raw, 0, self::MAX_RAW_BYTES);
            $payload['rawTruncated'] = true;
        }
        if (preg_match('//u', $raw) !== 1) {
            $raw = (string) preg_replace('/[\x80-\xFF]/', '?', $raw);
        }
        $payload['raw'] = $raw;

        return $payload;
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    private static function withoutNulls(array $payload): array
    {
        return array_filter($payload, static function ($value): bool {
            return $value !== null;
        });
    }

    /**
     * Rows as returned by Laravel (objects), Doctrine, $wpdb, or PDO (arrays), or a
     * collection of them; null when `$rows` isn't a list of rows.
     *
     * @param mixed $rows
     * @return array<int, array<string, mixed>>|null
     */
    private static function rowList($rows): ?array
    {
        if (is_object($rows) && !$rows instanceof \Traversable && method_exists($rows, 'all')) {
            $rows = $rows->all();
        }
        if ($rows instanceof \Traversable) {
            $rows = iterator_to_array($rows, false);
        }
        if (!is_array($rows)) {
            return null;
        }
        $list = [];
        foreach (array_slice(array_values($rows), 0, self::MAX_ROWS) as $row) {
            if (is_object($row)) {
                $row = get_object_vars($row);
            }
            if (!is_array($row) || $row === []) {
                return null;
            }
            $list[] = $row;
        }

        return $list;
    }

    /**
     * The dialect, server version, origin, and connection name of what the tab passed as
     * its connection. Nothing is sent to the database.
     *
     * @param mixed $connection
     * @return array{0: string|null, 1: string|null, 2: string|null, 3: string|null}
     */
    private static function describe($connection): array
    {
        if (is_string($connection)) {
            $names = ['mysql' => 'mysql', 'mariadb' => 'mariadb', 'pgsql' => 'pgsql', 'postgres' => 'pgsql', 'postgresql' => 'pgsql', 'sqlite' => 'sqlite', 'sqlite3' => 'sqlite'];

            return [$names[strtolower($connection)] ?? null, null, null, null];
        }
        if ($connection instanceof \PDO) {
            $version = self::serverVersion($connection);

            return [self::knownDialect(self::pdoDriver($connection), $version), $version, 'PDO', null];
        }
        if (!is_object($connection)) {
            return [null, null, null, null];
        }
        try {
            if (is_a($connection, 'Illuminate\Database\Connection')) {
                $pdo = method_exists($connection, 'getReadPdo') ? $connection->getReadPdo() : $connection->getPdo();
                $version = $pdo instanceof \PDO ? self::serverVersion($pdo) : null;
                $driver = method_exists($connection, 'getDriverName') ? (string) $connection->getDriverName() : ($pdo instanceof \PDO ? self::pdoDriver($pdo) : null);

                return [self::knownDialect($driver, $version), $version, 'Illuminate database connection', method_exists($connection, 'getName') ? $connection->getName() : null];
            }
            if (is_a($connection, 'Doctrine\DBAL\Connection')) {
                $native = \Runlet\SqlConnections::doctrine($connection);
                $version = $native instanceof \PDO ? self::serverVersion($native) : null;
                $platform = strtolower(get_class($connection->getDatabasePlatform()));
                $driver = strpos($platform, 'mariadb') !== false ? 'mariadb' : (strpos($platform, 'mysql') !== false ? 'mysql' : (strpos($platform, 'postgre') !== false ? 'pgsql' : (strpos($platform, 'sqlite') !== false ? 'sqlite' : null)));

                return [self::knownDialect($driver, $version), $version, 'Doctrine DBAL', null];
            }
            if (is_a($connection, 'wpdb')) {
                if (is_a($connection, 'WP_SQLite_DB')) {
                    return [null, null, 'WordPress $wpdb', null];
                }
                $version = method_exists($connection, 'db_server_info') ? $connection->db_server_info() : null;
                $version = is_string($version) && $version !== '' ? $version : null;

                return [self::knownDialect('mysql', $version), $version, 'WordPress $wpdb', null];
            }
        } catch (\Throwable $error) {
            // A connection that can't say: the rows tell the database.
        }

        return [null, null, null, null];
    }

    /** `mysql` (or `mariadb` by its server version), `pgsql`, `sqlite`; null for others. */
    private static function knownDialect(?string $driver, ?string $serverVersion): ?string
    {
        switch ($driver) {
            case 'mysql':
            case 'mariadb':
                return $driver === 'mariadb' || ($serverVersion !== null && stripos($serverVersion, 'mariadb') !== false) ? 'mariadb' : 'mysql';
            case 'pgsql':
            case 'sqlite':
                return $driver;
            default:
                return null;
        }
    }

    private static function pdoDriver(\PDO $pdo): ?string
    {
        try {
            return (string) $pdo->getAttribute(\PDO::ATTR_DRIVER_NAME);
        } catch (\Throwable $error) {
            return null;
        }
    }

    /**
     * The database's EXPLAIN dialect: from the PDO driver (MariaDB by its server version), or
     * $wpdb's MySQL. Anything else is refused here.
     *
     * @param \PDO|callable $source
     */
    private static function dialect($source, string $origin, ?string $driverName, ?string $serverVersion): string
    {
        switch ($driverName) {
            case 'mysql':
                if ($serverVersion === null && !$source instanceof \PDO) {
                    $serverVersion = self::callableVersion($source);
                }

                return $serverVersion !== null && stripos($serverVersion, 'mariadb') !== false ? 'mariadb' : 'mysql';
            case 'pgsql':
            case 'sqlite':
                return $driverName;
            case 'sqlsrv':
            case 'dblib':
                throw new SqlExplainRefused('Explain Statement doesn\'t support SQL Server yet (its plans come from SET SHOWPLAN_XML). Nothing ran.');
            case null:
                throw new SqlExplainRefused('Explain Statement needs to know the database, and this connection (' . $origin . ') runs statements through a callable. Return a PDO from the driver\'s sqlConnection(), or write EXPLAIN in the tab yourself and run it. Nothing ran.');
            default:
                throw new SqlExplainRefused('Explain Statement supports MySQL, MariaDB, PostgreSQL, and SQLite; this connection uses the ' . $driverName . ' driver. Write EXPLAIN in the tab yourself and run it. Nothing ran.');
        }
    }

    /** Explain Analyze runs the statement; refuses what can't be undone. */
    private static function refuseAnalyze(string $dialect, string $sql): void
    {
        if ($dialect === 'sqlite') {
            throw new SqlExplainRefused('SQLite has no EXPLAIN ANALYZE. Explain Statement shows SQLite\'s query plan without running the statement. Nothing ran.');
        }
        if ($dialect !== 'mysql' && $dialect !== 'mariadb') {
            return;
        }
        $why = SqlReadOnly::refusal($sql, 'mysql');
        if ($why !== null) {
            throw new SqlExplainRefused('Explain Analyze runs the statement, and Runlet runs only reading statements that way on ' . ($dialect === 'mariadb' ? 'MariaDB' : 'MySQL') . ': this one ' . $why
                . '. MySQL and MariaDB commit DDL at once and can\'t roll back non-transactional tables, so Runlet can\'t undo it. Explain Statement (without Analyze) shows its plan without running it. Nothing ran.');
        }
    }

    /** @return array{0: string, 1: string} The EXPLAIN to put first, and the output's format. */
    private static function prefix(string $dialect, bool $analyze): array
    {
        switch ($dialect) {
            case 'pgsql':
                return [$analyze ? 'EXPLAIN (ANALYZE, FORMAT JSON)' : 'EXPLAIN (FORMAT JSON)', 'json'];
            case 'sqlite':
                return ['EXPLAIN QUERY PLAN', 'rows'];
            case 'mariadb':
                return [$analyze ? 'ANALYZE FORMAT=JSON' : 'EXPLAIN FORMAT=JSON', 'json'];
            default:
                return [$analyze ? 'EXPLAIN ANALYZE' : 'EXPLAIN FORMAT=JSON', $analyze ? 'tree' : 'json'];
        }
    }

    /**
     * Runs the EXPLAIN with native prepares (MySQL and PostgreSQL then refuse a second
     * statement; SQLite compiles only the first) and returns its rows with column names.
     *
     * @param callable(\PDOStatement): void|null $bind
     * @return array<int, array<string, mixed>>
     */
    private static function fetchPdo(\PDO $pdo, string $dialect, string $sql, ?callable $bind): array
    {
        $restore = [\PDO::ATTR_ERRMODE => $pdo->getAttribute(\PDO::ATTR_ERRMODE)];
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        if ($dialect !== 'sqlite') {
            try {
                $previous = $pdo->getAttribute(\PDO::ATTR_EMULATE_PREPARES);
                if ($pdo->setAttribute(\PDO::ATTR_EMULATE_PREPARES, false)) {
                    $restore[\PDO::ATTR_EMULATE_PREPARES] = $previous;
                }
            } catch (\Throwable $error) {
                // The driver has no such setting: it prepares natively.
            }
        }
        try {
            $statement = $pdo->prepare($sql);
            if ($bind !== null) {
                $bind($statement);
            }
            $statement->execute();
            $rows = $statement->fetchAll(\PDO::FETCH_ASSOC);
            $statement->closeCursor();

            return is_array($rows) ? $rows : [];
        } finally {
            foreach ($restore as $attribute => $value) {
                try {
                    $pdo->setAttribute($attribute, $value);
                } catch (\Throwable $error) {
                    // Best effort: the run ends right after this.
                }
            }
        }
    }

    /**
     * @param callable $run
     * @return array<int, array<string, mixed>>
     */
    private static function fetchCallable(callable $run, string $sql): array
    {
        $returned = $run($sql);
        if (!is_iterable($returned)) {
            throw new \UnexpectedValueException('The SQL connection callable returned no rows for the EXPLAIN.');
        }
        $rows = [];
        foreach ($returned as $row) {
            $rows[] = is_object($row) ? get_object_vars($row) : (is_array($row) ? $row : ['value' => $row]);
            if (count($rows) >= self::MAX_ROWS) {
                break;
            }
        }

        return $rows;
    }

    /**
     * The JSON (or MySQL's tree) from the first row's first column; several rows (an older
     * MySQL's tabular EXPLAIN, a callable's) are joined.
     *
     * @param array<int, array<string, mixed>> $rows
     */
    private static function rawText(array $rows, string $dialect): string
    {
        if ($rows === []) {
            throw new \UnexpectedValueException('The database returned no plan.');
        }
        $parts = [];
        foreach ($rows as $row) {
            $value = reset($row);
            if (is_resource($value)) {
                $value = (string) stream_get_contents($value);
            }
            $parts[] = is_scalar($value) ? (string) $value : (string) json_encode($value);
        }

        return implode("\n", $parts);
    }

    /**
     * SQLite's EXPLAIN QUERY PLAN rows as `[id, parent, detail]` (SQLite before 3.24 has no
     * `parent`; its rows stay flat).
     *
     * @param array<int, array<string, mixed>> $rows
     * @return array<int, array{0: int, 1: int, 2: string}>
     */
    private static function planRows(array $rows): array
    {
        $plan = [];
        foreach (array_slice($rows, 0, self::MAX_ROWS) as $index => $row) {
            $detail = $row['detail'] ?? end($row);
            $plan[] = [
                isset($row['id']) ? (int) $row['id'] : $index + 1,
                isset($row['parent']) ? (int) $row['parent'] : 0,
                is_scalar($detail) ? (string) $detail : '',
            ];
        }

        return $plan;
    }

    private static function serverVersion(\PDO $pdo): ?string
    {
        try {
            $version = $pdo->getAttribute(\PDO::ATTR_SERVER_VERSION);
        } catch (\Throwable $error) {
            return null;
        }

        return is_string($version) && $version !== '' ? $version : null;
    }

    /** $wpdb's server version, to tell MariaDB from MySQL. */
    private static function callableVersion(callable $run): ?string
    {
        try {
            foreach ($run('SELECT VERSION() AS version') as $row) {
                $fields = is_object($row) ? get_object_vars($row) : (array) $row;
                $value = reset($fields);

                return is_string($value) ? $value : null;
            }
        } catch (\Throwable $error) {
            return null;
        }

        return null;
    }

    /** The statement's first word, upper-cased, after comments and blank space. */
    private static function firstWord(string $sql): string
    {
        $text = (string) preg_replace('~^(\s+|--[^\n]*(\n|$)|#[^\n]*(\n|$)|/\*.*?\*/)+~s', '', $sql);

        return preg_match('/^([A-Za-z_]+)/', $text, $match) === 1 ? strtoupper($match[1]) : '';
    }

    /** `SELECT 1;` → `SELECT 1`: the EXPLAIN goes in front of one statement. */
    private static function withoutTrailingSemicolon(string $sql): string
    {
        return (string) preg_replace('/;\s*$/', '', rtrim($sql));
    }
}

namespace Runlet;

/**
 * Shows EXPLAIN rows as Runlet's plan card (#170): the plan as a tree with full scans
 * highlighted, and the database's own output under Raw, as Explain Statement in SQL tabs
 * does (#147). The run inspector's Explain tab ends with it:
 *
 *     $connection = DB::connection('mysql');
 *     $plan = $connection->select('EXPLAIN FORMAT=JSON select * from users where email = ?', ['ada@example.com']);
 *     return \Runlet\explainPlan($plan, $connection);
 *
 * Pass the rows of `EXPLAIN FORMAT=JSON` (MySQL, MariaDB), `EXPLAIN (FORMAT JSON)`
 * (PostgreSQL), or `EXPLAIN QUERY PLAN` (SQLite), and the connection they came from: a PDO,
 * an Illuminate or Doctrine DBAL connection, $wpdb, or the database's name (`mysql`,
 * `mariadb`, `pgsql`, `sqlite`). The connection tells MariaDB from MySQL; nothing is sent to
 * the database.
 *
 * @param mixed $rows the EXPLAIN's rows, as objects or arrays
 * @param mixed $connection the connection, or the database's name; null tells by the rows
 * @param string|null $connectionName the name the card shows for the connection
 * @return mixed nothing to show when Runlet shows the plan; otherwise (a tabular MySQL
 *         EXPLAIN, PostgreSQL's text plan, an unknown database) the rows as they are
 */
function explainPlan($rows, $connection = null, ?string $connectionName = null)
{
    $plan = \RunletRunner\SqlExplain::fromRows($rows, $connection, $connectionName);
    if ($plan === null) {
        return $rows;
    }
    \RunletRunner\Channel::emit('sqlPlan', $plan);

    return \RunletRunner\NoResult::instance();
}
