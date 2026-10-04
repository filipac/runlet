<?php

declare(strict_types=1);

/*
 * Export Query to CSV and Import CSV (#152), on an SQL tab's connection (SqlTab::openFor: the
 * application's own, or a saved one, with the same refusals as a run).
 *
 * Export streams every row of a read statement as `sqlExport` frames (the columns, then at most
 * FRAME_ROWS rows or about FRAME_BYTES of cells per frame, then `done`), with no row cap, while
 * this process holds one frame at a time: MySQL and MariaDB fetch unbuffered, PostgreSQL through
 * a cursor in a read transaction (FETCH FORWARD), SQLite and SQL Server step through the rows.
 * The app writes each frame to the chosen file as it arrives (CSV is formatted there, with the
 * sheet's options). Stop cancels the statement on the server first (#144).
 *
 * Import inserts rows the app parsed from a CSV file and sent as data, in batches of JSON (never
 * SQL), with bound values, all in one transaction: committed after the last row, rolled back at
 * the first error, which says which row failed (a savepoint per statement lets Runlet find it).
 * A read-only connection refuses it (#139).
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

/** Export Query to CSV refused the statement or the connection; nothing was exported. */
final class SqlExportRefused extends \RuntimeException
{
}

/** Import CSV failed: the transaction was rolled back (the message says what came of it). */
final class SqlImportFailed extends \RuntimeException
{
}

/** One row (or one statement's rows) of an import that the database refused. */
final class SqlImportRowFailed extends \RuntimeException
{
    /** @var int|null 1-based data row; null when the statement failed but no single row did. */
    public $row;

    public function __construct(\Throwable $cause, ?int $row)
    {
        parent::__construct($cause->getMessage(), 0, $cause);
        $this->row = $row;
    }
}

final class SqlCsv
{
    /** Rows per `sqlExport` frame. */
    private const FRAME_ROWS = 1000;
    /** Cell bytes after which a frame is sent before it has FRAME_ROWS rows. */
    private const FRAME_BYTES = 262144;
    /** Rows a PostgreSQL cursor fetches at a time. */
    private const CURSOR_ROWS = 1000;
    /** Placeholders per INSERT at most (SQLite before 3.32 allows 999). */
    private const MAX_PLACEHOLDERS = 999;
    /** Rows per INSERT at most. */
    private const MAX_STATEMENT_ROWS = 500;

    /**
     * Export Query to CSV: every row of `$sql` (a read; the app checks Load Next's rules first)
     * as `sqlExport` frames. `$params` are its bound values (#145).
     *
     * @param array<int, array<string, mixed>> $params
     */
    public static function export(string $sql, ?string $connection, array $params = []): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        [$source, $origin, $driver, $fields] = SqlTab::openFor($sql, $connection, $params);
        SqlCancel::report($source, $connection); // #144: Stop cancels the statement on the server.
        $started = hrtime(true);
        $total = $source instanceof \PDO ? self::exportPdo($source, $driver, $sql, $params) : self::exportCallable($source, $sql);
        Channel::emit('sqlExport', ['done' => true, 'total' => $total, 'driver' => $driver, 'elapsedMs' => round((hrtime(true) - $started) / 1e6, 3), 'source' => $origin] + $fields);

        return NoResult::instance();
    }

    /**
     * Import CSV: inserts the rows of the request's batches (Runner::takeSqlBatches: JSON arrays
     * of rows of `$columns` values, a string or null each; `$batches` in tests) with `$prefix` (`INSERT INTO <table> (<columns>) VALUES`) and one
     * `$placeholders` (`(?, ?)`) per row, both built by the app, in one transaction. Emits
     * `sqlImport` after each batch, and at the end (`done`) or on a failure (`failedRow`,
     * `rolledBack`, then an SqlImportFailed error).
     *
     * @param string[] $batches
     */
    public static function import(string $prefix, string $placeholders, int $columns, ?string $connection, ?array $batches = null): NoResult
    {
        $batches = $batches ?? Runner::takeSqlBatches();
        $connection = $connection === '' ? null : $connection;
        if ($columns < 1 || preg_match('/^INSERT INTO\s.+\sVALUES$/s', $prefix) !== 1 || $placeholders !== '(' . implode(', ', array_fill(0, $columns, '?')) . ')') {
            throw new \InvalidArgumentException('Import CSV got a statement Runlet didn\'t build. Nothing was imported.');
        }
        // A read-only connection (#139) refuses the INSERT here, before anything is sent.
        [$source, $origin, $driver, $fields] = SqlTab::openFor($prefix . ' ' . $placeholders, $connection);
        if (!$source instanceof \PDO) {
            throw new SqlImportFailed('Import CSV binds every value, and this connection (' . $origin . ') runs statements through a callable, which can\'t bind values. Nothing was imported. Return a PDO from the driver\'s sqlConnection(), or save a connection for this database.');
        }
        SqlCancel::report($source, $connection, true); // #144
        $source->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        if ($driver === 'mysql') {
            try {
                $source->setAttribute(\PDO::ATTR_EMULATE_PREPARES, false);
            } catch (\Throwable $error) {
                // Bound either way.
            }
        }
        $perStatement = max(1, min(self::MAX_STATEMENT_ROWS, intdiv(self::MAX_PLACEHOLDERS, $columns)));
        $savepoints = in_array($driver, ['sqlite', 'mysql', 'pgsql'], true);
        $started = hrtime(true);
        try {
            $source->beginTransaction();
        } catch (\Throwable $error) {
            throw new SqlImportFailed('Runlet could not start a transaction on this connection: ' . $error->getMessage() . ' Nothing was imported.', 0, $error);
        }
        $inserted = 0;
        $statements = [];
        try {
            foreach (array_keys($batches) as $key) {
                // One batch at a time, freed once read.
                $rows = json_decode((string) $batches[$key], true);
                unset($batches[$key]);
                if (!is_array($rows)) {
                    throw new \InvalidArgumentException('Import CSV got a batch of rows it can\'t read.');
                }
                foreach (array_chunk($rows, $perStatement) as $chunk) {
                    self::insert($source, $prefix, $placeholders, $columns, $chunk, $inserted, $savepoints, $statements);
                    $inserted += count($chunk);
                }
                $rows = null;
                Channel::emit('sqlImport', ['inserted' => $inserted]);
            }
            $source->commit();
        } catch (\Throwable $error) {
            $row = $error instanceof SqlImportRowFailed ? $error->row : null;
            $cause = $error instanceof SqlImportRowFailed && $error->getPrevious() !== null ? $error->getPrevious() : $error;
            $rolledBack = true;
            $note = '';
            try {
                if ($source->inTransaction()) {
                    $source->rollBack();
                }
            } catch (\Throwable $rollback) {
                $rolledBack = false;
                $note = ' Runlet could not roll back the transaction (' . $rollback->getMessage() . '); the database rolls it back when the connection closes, right after this.';
            }
            $where = $row !== null ? 'Row ' . $row : ($inserted > 0 ? 'A row after the first ' . $inserted : 'A row');
            Channel::emit('sqlImport', array_filter(['inserted' => 0, 'failedRow' => $row, 'message' => $cause->getMessage(), 'rolledBack' => $rolledBack, 'driver' => $driver], static function ($value): bool {
                return $value !== null;
            }));
            $message = rtrim($cause->getMessage());
            $message .= preg_match('/[.!?]$/', $message) === 1 ? '' : '.';
            throw new SqlImportFailed($where . ' failed: ' . $message . ($rolledBack ? ' Rolled back the transaction: no rows were imported.' : '') . $note, 0, $cause);
        }
        Channel::emit('sqlImport', ['inserted' => $inserted, 'done' => true, 'driver' => $driver, 'elapsedMs' => round((hrtime(true) - $started) / 1e6, 3), 'source' => $origin] + $fields);

        return NoResult::instance();
    }

    /**
     * Inserts one statement's rows. When it fails, the savepoint before it is restored and the
     * rows go in one at a time, so the error names the row the database refused.
     *
     * @param array<int, mixed> $chunk
     * @param array<int, \PDOStatement> $statements Prepared INSERTs by row count.
     */
    private static function insert(\PDO $pdo, string $prefix, string $placeholders, int $columns, array $chunk, int $before, bool $savepoints, array &$statements): void
    {
        $count = count($chunk);
        $values = [];
        foreach ($chunk as $index => $row) {
            if (!is_array($row) || count($row) !== $columns) {
                throw new SqlImportRowFailed(new \InvalidArgumentException('The row has ' . (is_array($row) ? count($row) : 0) . ' values for ' . $columns . ' columns.'), $before + $index + 1);
            }
            foreach ($row as $value) {
                $values[] = $value === null ? null : (string) $value;
            }
        }
        if (!isset($statements[$count])) {
            $statements[$count] = $pdo->prepare($prefix . ' ' . implode(', ', array_fill(0, $count, $placeholders)));
        }
        if ($savepoints && $count > 1) {
            $pdo->exec('SAVEPOINT runlet_import');
        }
        try {
            self::bindAll($statements[$count], $values);
            $statements[$count]->execute();
            if ($savepoints && $count > 1) {
                $pdo->exec('RELEASE SAVEPOINT runlet_import');
            }

            return;
        } catch (\PDOException $error) {
            if (!$savepoints || $count === 1) {
                throw new SqlImportRowFailed($error, $count === 1 ? $before + 1 : null);
            }
            $pdo->exec('ROLLBACK TO SAVEPOINT runlet_import');
        }
        if (!isset($statements[1])) {
            $statements[1] = $pdo->prepare($prefix . ' ' . $placeholders);
        }
        foreach ($chunk as $index => $row) {
            try {
                self::bindAll($statements[1], array_map(static function ($value) {
                    return $value === null ? null : (string) $value;
                }, array_values($row)));
                $statements[1]->execute();
            } catch (\PDOException $error) {
                throw new SqlImportRowFailed($error, $before + $index + 1);
            }
        }
        // The rows went in one by one; the statement of all of them didn't (a limit of the database's).
    }

    /** @param array<int, string|null> $values */
    private static function bindAll(\PDOStatement $statement, array $values): void
    {
        foreach ($values as $index => $value) {
            $statement->bindValue($index + 1, $value, $value === null ? \PDO::PARAM_NULL : \PDO::PARAM_STR);
        }
    }

    /**
     * @param array<int, array<string, mixed>> $params
     */
    private static function exportPdo(\PDO $pdo, ?string $driver, string $sql, array $params): int
    {
        $restore = [\PDO::ATTR_ERRMODE => $pdo->getAttribute(\PDO::ATTR_ERRMODE)];
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $attributes = [];
        if ($driver === 'mysql' || $params !== []) {
            // Native prepares, as for a run: one statement, values apart from the SQL.
            $attributes[\PDO::ATTR_EMULATE_PREPARES] = false;
        }
        if ($driver === 'mysql') {
            // Unbuffered: the rows stream from the server instead of being held here.
            $buffered = defined('Pdo\Mysql::ATTR_USE_BUFFERED_QUERY') ? constant('Pdo\Mysql::ATTR_USE_BUFFERED_QUERY') : (defined('PDO::MYSQL_ATTR_USE_BUFFERED_QUERY') ? constant('PDO::MYSQL_ATTR_USE_BUFFERED_QUERY') : null);
            if ($buffered !== null) {
                $attributes[(int) $buffered] = false;
            }
        }
        foreach ($attributes as $attribute => $value) {
            try {
                $previous = $pdo->getAttribute($attribute);
                if ($pdo->setAttribute($attribute, $value)) {
                    $restore[$attribute] = $previous;
                }
            } catch (\Throwable $error) {
                // Not supported here: the connection's setting stays.
            }
        }
        try {
            if ($driver === 'pgsql' && !$pdo->inTransaction()) {
                return self::exportCursor($pdo, $sql, $params);
            }
            $statement = $pdo->prepare($sql);
            SqlTab::bindValues($statement, $params);
            $statement->execute();
            if ($statement->columnCount() <= 0) {
                throw new SqlExportRefused('The statement returned no rows to export (it affected ' . $statement->rowCount() . ').');
            }
            self::emitColumns($statement, $driver);
            $total = 0;
            $frame = [];
            $bytes = 0;
            while (($row = $statement->fetch(\PDO::FETCH_NUM)) !== false) {
                self::add($row, $frame, $bytes, $total);
            }
            self::flush($frame, $bytes, $total);
            $statement->closeCursor();

            return $total;
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
     * PostgreSQL holds a whole result in the client unless it comes through a cursor: in a
     * transaction that only reads (rolled back at the end), `DECLARE … CURSOR FOR` the
     * statement, then FETCH FORWARD in steps of CURSOR_ROWS.
     *
     * @param array<int, array<string, mixed>> $params
     */
    private static function exportCursor(\PDO $pdo, string $sql, array $params): int
    {
        $pdo->beginTransaction();
        try {
            $declare = $pdo->prepare('DECLARE runlet_export NO SCROLL CURSOR FOR ' . $sql);
            SqlTab::bindValues($declare, $params);
            $declare->execute();
            $total = 0;
            $frame = [];
            $bytes = 0;
            $first = true;
            while (true) {
                $fetch = $pdo->query('FETCH FORWARD ' . self::CURSOR_ROWS . ' FROM runlet_export');
                if ($fetch === false) {
                    break;
                }
                if ($first) {
                    self::emitColumns($fetch, 'pgsql');
                    $first = false;
                }
                $fetched = 0;
                while (($row = $fetch->fetch(\PDO::FETCH_NUM)) !== false) {
                    $fetched++;
                    self::add($row, $frame, $bytes, $total);
                }
                $fetch->closeCursor();
                if ($fetched < self::CURSOR_ROWS) {
                    break;
                }
            }
            self::flush($frame, $bytes, $total);
            $pdo->exec('CLOSE runlet_export');

            return $total;
        } finally {
            try {
                if ($pdo->inTransaction()) {
                    $pdo->rollBack(); // It only read.
                }
            } catch (\Throwable $error) {
                // The connection closes right after this.
            }
        }
    }

    /** A callable connection (WordPress's $wpdb, …): the rows it returns, in frames. */
    private static function exportCallable(callable $run, string $sql): int
    {
        $returned = $run($sql);
        if (is_int($returned)) {
            throw new SqlExportRefused('The statement returned no rows to export (it affected ' . $returned . ').');
        }
        if (!is_iterable($returned)) {
            throw new \UnexpectedValueException('The SQL connection callable returned ' . (is_object($returned) ? get_class($returned) : gettype($returned)) . '; return the rows (an iterable of arrays or objects) or the number of affected rows (an int).');
        }
        $columns = null;
        $total = 0;
        $frame = [];
        $bytes = 0;
        foreach ($returned as $row) {
            $fields = is_object($row) ? get_object_vars($row) : (is_array($row) ? $row : ['value' => $row]);
            if ($columns === null) {
                $columns = array_map('strval', array_keys($fields));
                Channel::emit('sqlExport', ['columns' => $columns]);
            }
            $values = [];
            foreach ($columns as $column) {
                $values[] = array_key_exists($column, $fields) ? $fields[$column] : null;
            }
            self::add($values, $frame, $bytes, $total);
        }
        if ($columns === null) {
            Channel::emit('sqlExport', ['columns' => []]);
        }
        self::flush($frame, $bytes, $total);

        return $total;
    }

    private static function emitColumns(\PDOStatement $statement, ?string $driver): void
    {
        $columns = [];
        for ($index = 0; $index < $statement->columnCount(); $index++) {
            try {
                $meta = $statement->getColumnMeta($index);
            } catch (\Throwable $error) {
                $meta = false;
            }
            $columns[] = is_array($meta) && isset($meta['name']) && $meta['name'] !== '' ? (string) $meta['name'] : 'column ' . ($index + 1);
        }
        Channel::emit('sqlExport', ['columns' => $columns, 'driver' => $driver]);
    }

    /**
     * @param array<int, mixed> $row
     * @param array<int, array<int, mixed>> $frame
     */
    private static function add(array $row, array &$frame, int &$bytes, int &$total): void
    {
        $cells = [];
        foreach ($row as $value) {
            $cells[] = self::cell($value, $bytes);
        }
        $frame[] = $cells;
        $total++;
        if (count($frame) >= self::FRAME_ROWS || $bytes >= self::FRAME_BYTES) {
            self::flush($frame, $bytes, $total);
        }
    }

    /** @param array<int, array<int, mixed>> $frame */
    private static function flush(array &$frame, int &$bytes, int $total): void
    {
        if ($frame === []) {
            return;
        }
        Channel::emit('sqlExport', ['rows' => $frame, 'total' => $total, 'bytes' => $bytes]);
        $frame = [];
        $bytes = 0;
    }

    /**
     * A whole value: null, a bool, a number, text, or `binary` (byte count) and `hex` (every
     * byte) for bytes that aren't UTF-8. Nothing is shortened.
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
        if (is_resource($value)) {
            // Large objects (PostgreSQL bytea, …) arrive as streams.
            $read = @stream_get_contents($value);
            $value = $read === false ? '' : $read;
        } elseif ($value instanceof \DateTimeInterface) {
            $value = $value->format('Y-m-d H:i:s.uP');
        } elseif (is_object($value)) {
            $value = method_exists($value, '__toString') ? (string) $value : get_class($value);
        } elseif (is_array($value)) {
            $encoded = json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR);
            $value = $encoded === false ? 'array' : $encoded;
        }
        $string = (string) $value;
        if (preg_match('//u', $string) !== 1) {
            $bytes += 2 * strlen($string);

            return ['binary' => strlen($string), 'hex' => strtoupper(bin2hex($string))];
        }
        $bytes += strlen($string);

        return $string;
    }
}
