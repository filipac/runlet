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
 * statement after a `;` instead of running it. Bound values (#145) use the shape
 * SqlTab::run() takes.
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
     * @param array<int, array<string, mixed>> $params
     * @return array<string, mixed>
     */
    public static function explain($source, string $origin, ?string $driverName, string $sql, bool $analyze, array $params = []): array
    {
        $serverVersion = $source instanceof \PDO ? self::serverVersion($source) : null;
        $dialect = self::dialect($source, $origin, $driverName, $serverVersion);
        if ($analyze) {
            self::refuseAnalyze($dialect, $sql);
        }
        if (!$source instanceof \PDO && $params !== []) {
            throw new SqlExplainRefused('This statement has placeholders, and this connection (' . $origin . ') runs statements through a callable, which can\'t bind values. Runlet never writes values into the SQL. Nothing ran.');
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
                $rows = self::fetchPdo($source, $dialect, $explained, $params);
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
            $raw = self::rawText($rows, $dialect);
            if (strlen($raw) > self::MAX_RAW_BYTES) {
                $raw = substr($raw, 0, self::MAX_RAW_BYTES);
                $payload['rawTruncated'] = true;
            }
            if (preg_match('//u', $raw) !== 1) {
                $raw = (string) preg_replace('/[\x80-\xFF]/', '?', $raw);
            }
            $payload['raw'] = $raw;
        }
        if ($rolledBack) {
            $payload['rolledBack'] = true;
        }

        return array_filter($payload, static function ($value): bool {
            return $value !== null;
        });
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
     * @param array<int, array<string, mixed>> $params
     * @return array<int, array<string, mixed>>
     */
    private static function fetchPdo(\PDO $pdo, string $dialect, string $sql, array $params): array
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
            self::bind($statement, $params);
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
     * Bound values (#145), as SqlTab::run() takes them: each `name` (without `:`) or 1-based
     * `position`, a `type` (`str`, `int`, `decimal`, `bool`, `null`), and its `value`.
     *
     * @param array<int, array<string, mixed>> $params
     */
    private static function bind(\PDOStatement $statement, array $params): void
    {
        foreach ($params as $param) {
            $value = $param['value'] ?? null;
            switch ((string) ($param['type'] ?? 'str')) {
                case 'int':
                    $type = \PDO::PARAM_INT;
                    $value = (int) $value;
                    break;
                case 'bool':
                    $type = \PDO::PARAM_BOOL;
                    $value = (bool) $value;
                    break;
                case 'null':
                    $type = \PDO::PARAM_NULL;
                    $value = null;
                    break;
                default:
                    $type = \PDO::PARAM_STR;
                    $value = (string) $value;
            }
            $statement->bindValue(isset($param['name']) ? ':' . $param['name'] : (int) ($param['position'] ?? 0), $value, $type);
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
