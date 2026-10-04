<?php

declare(strict_types=1);

/*
 * Browse Table (#151): the schema explorer opens one table in the result window, a page at a
 * time, and on a table with a primary key lets the user change cells, add rows, and delete
 * rows. The app writes every statement (SQLTableBrowse and SQLTableEdits in RunletCore): names
 * come from the schema's column list, quoted for the dialect, and every value is bound, never
 * written into the SQL. This file checks what it is given and runs it:
 *  - checkBrowse(): a page is one SELECT, written for the connection's dialect
 *    (SqlTab::browse() runs it like a statement and emits its `sql` event);
 *  - apply(): the reviewed changes, in one transaction. Each must affect exactly one row;
 *    otherwise everything is rolled back and the error says which change and why (a row that
 *    someone else changed or deleted since the page was read is not found). MySQL and MariaDB
 *    count only the rows an UPDATE changed, so when one reports none, the change's `verify`
 *    count (the same WHERE, written by the app) decides whether the row was there.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

/** Browse Table (#151) refused what it was given; nothing ran. */
final class SqlTableRefused extends \RuntimeException
{
}

/**
 * Apply (#151) stopped at a change that failed or didn't affect exactly one row, and rolled
 * everything back. The message says which change, why, and what the rollback did.
 */
final class SqlEditsFailed extends \RuntimeException
{
}

final class SqlTable
{
    /** The statements Apply runs, by kind. */
    private const KINDS = ['update' => 'UPDATE', 'insert' => 'INSERT', 'delete' => 'DELETE'];
    /** Bytes of a change's SQL echoed back with its result. */
    private const MAX_ECHO_BYTES = 2000;

    /**
     * A page's SQL: one SELECT that reads, written for the dialect of the connection's PDO driver
     * (`$expected`; null for a callable connection, whose dialect Runlet can't check).
     */
    public static function checkBrowse(string $sql, ?string $actual, ?string $expected): void
    {
        self::checkDialect($actual, $expected, 'Browse Table');
        if (preg_match('/^\s*SELECT\s/i', $sql) !== 1 || SqlReadOnly::refusal($sql, $actual ?? $expected) !== null) {
            throw new SqlTableRefused('Browse Table runs only the SELECT Runlet wrote for a page of the table. Nothing ran.');
        }
    }

    /** The SQL was written for `$expected`'s dialect; the connection must still be one. */
    public static function checkDialect(?string $actual, ?string $expected, string $what): void
    {
        if ($expected === null || $expected === '') {
            return;
        }
        if (self::dialect($actual) !== self::dialect($expected)) {
            throw new SqlTableRefused('The connection is ' . ($actual === null ? 'no PDO connection' : 'a ' . $actual . ' connection') . ' now, and ' . $what . ' wrote its SQL for ' . $expected . '. Load the schema again and browse the table again. Nothing ran.');
        }
    }

    /**
     * Apply's changes, before the connection opens: each is an UPDATE, INSERT, or DELETE of its
     * kind, and a `verify` count is a SELECT.
     *
     * @param array<int, array<string, mixed>> $statements
     */
    public static function checkEdits(array $statements): void
    {
        if ($statements === []) {
            throw new SqlTableRefused('There are no changes to apply.');
        }
        foreach (array_values($statements) as $index => $statement) {
            $kind = (string) ($statement['kind'] ?? '');
            $sql = (string) ($statement['sql'] ?? '');
            $verify = isset($statement['verify']) ? (string) $statement['verify'] : null;
            if (!isset(self::KINDS[$kind]) || preg_match('/^\s*' . self::KINDS[$kind] . '\s/i', $sql) !== 1
                || ($verify !== null && ($kind !== 'update' || preg_match('/^\s*SELECT\s+COUNT\(\*\)\s/i', $verify) !== 1))) {
                throw new SqlTableRefused('Change ' . ($index + 1) . ' isn\'t an UPDATE, INSERT, or DELETE that Review Changes wrote. Nothing ran.');
            }
        }
    }

    /**
     * Runs `$statements` in order, in one transaction on `$pdo`, and returns one `sql` event
     * payload per change (its affected rows and the change). Each change must affect exactly
     * one row: when one affects none (the row is gone, or changed where the WHERE checks it) or
     * more, or fails, the transaction is rolled back and SqlEditsFailed says which change and
     * why. Values are bound by `$bind` (SqlTab::bind()), with native prepares.
     *
     * @param array<int, array<string, mixed>> $statements
     * @param callable(\PDOStatement, array<int, array<string, mixed>>): void $bind
     * @return array<int, array<string, mixed>>
     */
    public static function apply(\PDO $pdo, ?string $driverName, array $statements, callable $bind): array
    {
        $statements = array_values($statements);
        $count = count($statements);
        $restore = [\PDO::ATTR_ERRMODE => $pdo->getAttribute(\PDO::ATTR_ERRMODE)];
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        try {
            // Native prepares: the values go to the database apart from the SQL.
            $previous = $pdo->getAttribute(\PDO::ATTR_EMULATE_PREPARES);
            if ($pdo->setAttribute(\PDO::ATTR_EMULATE_PREPARES, false)) {
                $restore[\PDO::ATTR_EMULATE_PREPARES] = $previous;
            }
        } catch (\Throwable $error) {
            // The driver has no such setting (SQLite always binds natively).
        }
        try {
            try {
                $pdo->beginTransaction();
            } catch (\Throwable $error) {
                throw new SqlEditsFailed('Runlet could not start a transaction on this connection: ' . $error->getMessage() . ' Nothing was changed.', 0, $error);
            }
            $results = [];
            foreach ($statements as $index => $statement) {
                $kind = (string) $statement['kind'];
                $sql = (string) $statement['sql'];
                $label = isset($statement['label']) ? (string) $statement['label'] : '';
                $which = 'Change ' . ($index + 1) . ' of ' . $count . ($label === '' ? '' : ' (' . $label . ')');
                $started = hrtime(true);
                $unchanged = false;
                try {
                    $prepared = $pdo->prepare($sql);
                    $bind($prepared, self::params($statement, 'params'));
                    $prepared->execute();
                    $affected = $prepared->rowCount();
                    $prepared->closeCursor();
                    if ($affected === 0 && $kind === 'update' && isset($statement['verify'])) {
                        // MySQL and MariaDB count changed rows: an UPDATE to the values the row
                        // already has changes none. The same WHERE, counted, says whether the
                        // row was there.
                        $check = $pdo->prepare((string) $statement['verify']);
                        $bind($check, self::params($statement, 'verifyParams'));
                        $check->execute();
                        $matched = (int) $check->fetchColumn();
                        $check->closeCursor();
                        if ($matched === 1) {
                            $affected = 1;
                            $unchanged = true;
                        } else {
                            $affected = $matched;
                        }
                    }
                } catch (DriverFailure $failure) {
                    self::rollBack($pdo);
                    throw $failure;
                } catch (\Throwable $error) {
                    throw new SqlEditsFailed($which . ': ' . $error->getMessage() . "\n\n" . self::rollBack($pdo), 0, $error);
                }
                if ($affected !== 1) {
                    if ($affected === 0) {
                        $why = $kind === 'insert'
                            ? 'the INSERT added no row'
                            : 'row not found: it was changed or deleted by someone else since the page was read (Runlet looks it up by its primary key' . ($kind === 'update' ? ' and the values you changed' : '') . ')';
                    } else {
                        $why = 'it would have affected ' . $affected . ' rows, not one';
                    }
                    throw new SqlEditsFailed($which . ': ' . $why . '.' . "\n\n" . self::rollBack($pdo));
                }
                $results[] = array_filter([
                    'driver' => $driverName,
                    'affectedRows' => 1,
                    'elapsedMs' => round((hrtime(true) - $started) / 1e6, 3),
                    'unchanged' => $unchanged ? true : null,
                    'statement' => ['index' => $index + 1, 'count' => $count, 'line' => $index + 1, 'text' => self::echoed($sql)],
                ], static function ($value): bool {
                    return $value !== null;
                });
            }
            try {
                $pdo->commit();
            } catch (\Throwable $error) {
                throw new SqlEditsFailed('All ' . $count . ' changes ran, but Runlet could not commit the transaction: ' . $error->getMessage() . ' The database has probably rolled it back.', 0, $error);
            }

            return $results;
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

    /** The notice after a commit. */
    public static function committed(int $count): string
    {
        return 'Committed the transaction: ' . ($count === 1 ? 'the change affected its row.' : 'all ' . $count . ' changes affected exactly one row each.');
    }

    /**
     * @param array<string, mixed> $statement
     * @return array<int, array<string, mixed>>
     */
    private static function params(array $statement, string $key): array
    {
        return isset($statement[$key]) && is_array($statement[$key]) ? array_values($statement[$key]) : [];
    }

    /** Rolls back and says so. */
    private static function rollBack(\PDO $pdo): string
    {
        try {
            if ($pdo->inTransaction()) {
                $pdo->rollBack();
            }
        } catch (\Throwable $error) {
            return 'Runlet could not roll back the transaction: ' . $error->getMessage() . ' Check the table: changes before this one may have stayed.';
        }

        return 'Rolled back the transaction: nothing was changed.';
    }

    /** sqlsrv and dblib are both SQL Server; sqlite2 is SQLite. */
    private static function dialect(?string $driver): ?string
    {
        switch ($driver) {
            case 'dblib':
                return 'sqlsrv';
            case 'sqlite2':
                return 'sqlite';
            default:
                return $driver;
        }
    }

    /** A change's SQL for its result, cut at a UTF-8 boundary. */
    private static function echoed(string $sql): string
    {
        $sql = trim($sql);
        if (strlen($sql) <= self::MAX_ECHO_BYTES) {
            return $sql;
        }
        $cut = substr($sql, 0, self::MAX_ECHO_BYTES);
        while ($cut !== '' && preg_match('//u', $cut) !== 1) {
            $cut = substr($cut, 0, -1);
        }

        return $cut . '…';
    }
}
