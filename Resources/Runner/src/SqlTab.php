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
 *     Symfony (Doctrine), or WordPress (its PDO from wp-config.php, else $wpdb, #208:
 *     WordPressDatabase.php) driver's. The application's own connections need no
 *     credentials from Runlet;
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
 * Bound parameters (#145): a statement with placeholders can't be bound on this connection (a
 * callable has no binding API, MySQL refuses a name used twice), so nothing ran. Runlet never
 * writes values into the SQL instead.
 */
final class SqlParametersRefused extends \RuntimeException
{
}

/**
 * Load Next (#146): the next page couldn't run (the connection's driver changed, or the
 * database refused the row limit Runlet added). Nothing was appended.
 */
final class SqlPageFailed extends \RuntimeException
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
     *
     * `$params` (#145) are the statement's bound values, each `name` (without `:`) or 1-based
     * `position`, a `type` (`str`, `int`, `decimal`, `bool`, `null`), and its `value`; they
     * are bound with PDOStatement::bindValue and never become part of the SQL.
     *
     * @param array<int, array<string, mixed>> $params
     */
    public static function run(string $sql, ?string $connection, int $maxRows, bool $schema = false, array $params = []): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        $maxRows = max(1, $maxRows);
        self::refuseOnReadOnly([['sql' => $sql, 'line' => 0]]);
        $names = self::connectionNames();
        [$source, $origin] = self::resolve($connection, $names);
        self::refuseUnbindable($source, $origin, [['sql' => $sql, 'line' => 0, 'params' => $params]]);
        SqlCancel::report($source, $connection); // #144: Stop can cancel the statement on the server.
        $started = hrtime(true);
        $common = ['source' => $origin, 'maxRows' => $maxRows] + self::connectionFields($connection);
        if (!$source instanceof \PDO) {
            $result = self::runCallable($source, $sql, $maxRows);
            $result['readNs'] = hrtime(true);
            $results = [$result];
        } else {
            // #154: every result set (a stored procedure's, a batch's), under one row and byte cap.
            $read = [];
            try {
                $results = self::runPdoSets($source, $sql, $maxRows, $params, $read);
            } catch (\Throwable $error) {
                // A later set failed: the sets read before it still show ("Result 1", …).
                self::emitResults($read, false, $common, $started, $names);
                throw $error;
            }
        }
        self::emitResults($results, true, $common, $started, $names);
        if ($schema) {
            self::emitSchema($connection, $source, $origin, $results[0]['driver'] ?? null);
        }

        return NoResult::instance();
    }

    /**
     * Emits a statement's results as `sql` events (#154): one for a single result, as before;
     * several labelled `resultSet` (index, and count when `$complete`) when the statement
     * returned more than one, or a later one failed after these were read. Each result's
     * `elapsedMs` runs from the statement's start to the end of reading it.
     *
     * @param array<int, array<string, mixed>> $results
     * @param array<string, mixed> $common Fields every result gets (source, maxRows, connection, statement).
     * @param string[] $names The connection names, sent with the first result.
     */
    private static function emitResults(array $results, bool $complete, array $common, int $started, array $names): void
    {
        $count = count($results);
        foreach (array_values($results) as $index => $result) {
            $result['elapsedMs'] = round(((int) ($result['readNs'] ?? hrtime(true)) - $started) / 1e6, 3);
            unset($result['readNs']);
            $result += $common;
            if ($index === 0 && $names !== []) {
                $result['connections'] = $names;
            }
            if ($count > 1 || !$complete) {
                $result['resultSet'] = $complete ? ['index' => $index + 1, 'count' => $count] : ['index' => $index + 1];
            }
            Channel::emit('sql', $result);
        }
    }

    /**
     * Load Next (#146): one page of a statement whose result the row cap cut, as an `sql`
     * event. The app builds `$sql` (SQLPaging in RunletCore): the statement as written, or with
     * a row limit added to its end (`$added`, e.g. `LIMIT 1001 OFFSET 1000`, written for PDO
     * driver `$driver`, which the connection must still be). `$skip` rows are fetched and
     * discarded first when the database doesn't skip them itself. `$params` are the first
     * run's bound values (#145). A read-only saved connection (#139) refuses as for a run.
     *
     * @param array<int, array<string, mixed>> $params
     */
    public static function page(string $sql, ?string $connection, int $maxRows, int $skip, ?string $driver, array $params = [], ?string $added = null): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        $maxRows = max(1, $maxRows);
        $skip = max(0, $skip);
        self::refuseOnReadOnly([['sql' => $sql, 'line' => 0]]);
        $names = self::connectionNames();
        [$source, $origin] = self::resolve($connection, $names);
        if ($driver !== null) {
            $actual = $source instanceof \PDO ? self::pdoDriverName($source) : null;
            if (self::dialect($actual) !== self::dialect($driver)) {
                throw new SqlPageFailed('The connection is ' . ($actual === null ? 'no longer a PDO connection' : 'a ' . $actual . ' connection now') . ', and Load Next wrote the next page for ' . $driver . '. Run the statement again.');
            }
        }
        self::refuseUnbindable($source, $origin, [['sql' => $sql, 'line' => 0, 'params' => $params]]);
        SqlCancel::report($source, $connection); // #144
        $started = hrtime(true);
        try {
            $result = $source instanceof \PDO ? self::runPdo($source, $sql, $maxRows, $params, $skip) : self::runCallable($source, $sql, $maxRows, $skip);
        } catch (DriverFailure $failure) {
            throw $failure;
        } catch (SqlParametersRefused $refused) {
            throw $refused;
        } catch (\Throwable $error) {
            if ($added === null) {
                throw $error;
            }
            throw new SqlPageFailed($error->getMessage() . "\n\nLoad Next added \u{201C}" . $added . "\u{201D} to the end of the statement. If the database can't take that, add LIMIT and OFFSET to the statement yourself.", 0, $error);
        }
        if (!isset($result['columns'])) {
            throw new SqlPageFailed('The statement returned no rows this time (' . (int) ($result['affectedRows'] ?? 0) . ' affected), so there is no next page.');
        }
        $result['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
        $result['source'] = $origin;
        $result['maxRows'] = $maxRows;
        $result += self::connectionFields($connection);
        Channel::emit('sql', $result);

        return NoResult::instance();
    }

    /**
     * Export Query to CSV and Import CSV (#152, SqlCsv.php): the run's connection for `$sql`,
     * after the refusals a run makes first (a read-only connection's, #139; values that can't
     * be bound, #145).
     *
     * @param array<int, array<string, mixed>> $params
     * @return array{0: \PDO|callable, 1: string, 2: ?string, 3: array<string, mixed>} The connection, where it came from, its PDO driver, and a result's `connection` fields.
     */
    public static function openFor(string $sql, ?string $connection, array $params = []): array
    {
        self::refuseOnReadOnly([['sql' => $sql, 'line' => 0]]);
        [$source, $origin] = self::resolve($connection, self::connectionNames());
        self::refuseUnbindable($source, $origin, [['sql' => $sql, 'line' => 0, 'params' => $params]]);

        return [$source, $origin, $source instanceof \PDO ? self::pdoDriverName($source) : null, self::connectionFields($connection)];
    }

    /**
     * Bound values (#145) for SqlCsv's statements (#152), in run()'s shape.
     *
     * @param array<int, array<string, mixed>> $params
     */
    public static function bindValues(\PDOStatement $statement, array $params): void
    {
        self::bind($statement, $params);
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
     * Stop (#144): cancels the running statement of session `$session` (reported by the run's
     * `sqlSession` event) on the same connection, opened again in this second runner, and
     * emits an `sqlCancel` event. `$statement` must be the dialect's own cancel statement
     * (SqlCancel::statement()); `$server` is the run's server fingerprint. Runlet's statement,
     * not the user's: read-only connections (#139) allow it.
     */
    public static function cancel(string $dialect, int $session, string $statement, ?string $connection, string $server = ''): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        [$source, $origin] = self::resolve($connection, []);
        Channel::emit('sqlCancel', SqlCancel::cancel($source, $origin, $dialect, $session, $statement, $server));

        return NoResult::instance();
    }

    /**
     * Explain Statement (#147): the plan of `$sql` on the tab's connection, as an `sqlPlan`
     * event. Plain Explain never runs the statement; `$analyze` runs it, guarded (SqlExplain).
     * `$params` are bound values (#145), in run()'s shape.
     *
     * @param array<int, array<string, mixed>> $params
     */
    public static function explain(string $sql, ?string $connection, bool $analyze, array $params = []): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        SqlExplain::refuseEarly($sql, $analyze);
        $names = self::connectionNames();
        [$source, $origin] = self::resolve($connection, $names);
        self::refuseUnbindable($source, $origin, [['sql' => $sql, 'line' => 0, 'params' => $params]]);
        SqlCancel::report($source, $connection); // #144
        $driverName = $source instanceof \PDO ? self::pdoDriverName($source) : (WordPressDatabase::isWpdb($origin) ? 'mysql' : null);
        $bind = static function (\PDOStatement $statement) use ($params): void {
            self::bind($statement, $params);
        };
        $started = hrtime(true);
        $plan = SqlExplain::explain($source, $origin, $driverName, $sql, $analyze, $bind);
        $plan['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
        $plan['source'] = $origin;
        $plan += self::connectionFields($connection);
        if ($names !== []) {
            $plan['connections'] = $names;
        }
        Channel::emit('sqlPlan', $plan);

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
     * Show Definition (#148): emits the definition (DDL) of one table or view as an
     * `sqlDefinition` event (SqlDefinition). Only the catalog is read; nothing is created,
     * changed, or run, and the app shows the DDL in a read-only sheet.
     */
    public static function definition(string $table, ?string $connection): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        [$source, $origin] = self::resolve($connection, self::connectionNames());
        $driverName = $source instanceof \PDO ? self::pdoDriverName($source) : null;
        $started = hrtime(true);
        try {
            $read = SqlDefinition::read($source, $origin, $driverName, $table);
        } catch (DriverFailure | SqlUnavailable | SqlDefinitionNotFound $refused) {
            throw $refused;
        } catch (\Throwable $error) {
            throw new SqlConnectionFailed('Runlet could not read the definition of ' . $table . ': ' . $error->getMessage(), 0, $error);
        }
        $payload = ['driver' => $driverName ?? ($read['dialect'] ?? null), 'source' => $origin] + self::connectionFields($connection) + $read;
        unset($payload['dialect']);
        $payload['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
        Channel::emit('sqlDefinition', array_filter($payload, static function ($value): bool {
            return $value !== null;
        }));

        return NoResult::instance();
    }

    /**
     * The Database pane's Server section (#150): emits the server's overview, sizes, and
     * sessions (`$parts`, all when empty) on the tab's connection as an `sqlServer` event
     * (SqlServerInfo). Only the catalog and the server's status are read, never table rows.
     *
     * @param string[] $parts
     */
    public static function server(array $parts, ?string $connection): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        [$source, $origin] = self::resolve($connection, self::connectionNames());
        $driverName = $source instanceof \PDO ? self::pdoDriverName($source) : null;
        $started = hrtime(true);
        try {
            $read = SqlServerInfo::read($source, $origin, $driverName, $parts);
        } catch (DriverFailure | SqlUnavailable $refused) {
            throw $refused;
        } catch (\Throwable $error) {
            throw new SqlConnectionFailed('Runlet could not read the server details: ' . $error->getMessage(), 0, $error);
        }
        $payload = ['driver' => $driverName, 'source' => $origin] + self::connectionFields($connection) + $read;
        unset($payload['dialect']);
        $payload['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
        Channel::emit('sqlServer', array_filter($payload, static function ($value): bool {
            return $value !== null;
        }));

        return NoResult::instance();
    }

    /**
     * The Server section's Cancel Query or Kill Session (#150), confirmed in the app: sends
     * `$statement` (SqlServerInfo::statement()) for `$session` on the same connection, opened
     * again in this runner, and emits an `sqlServerAction` event. `$server` is the list's server
     * fingerprint, `$listedBy` the session the list was read with (refused, like this runner's
     * own), and `$user`/`$started` what the list showed for the session. Runlet's statement,
     * not the user's: read-only connections (#139) allow it.
     */
    public static function serverAction(string $action, string $dialect, int $session, string $statement, ?string $connection, string $server, int $listedBy, string $user = '', string $started = ''): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        [$source, $origin] = self::resolve($connection, []);
        $driverName = $source instanceof \PDO ? self::pdoDriverName($source) : null;
        Channel::emit('sqlServerAction', SqlServerInfo::act($source, $origin, $driverName, $action, $dialect, $session, $statement, $server, $listedBy, $user, $started));

        return NoResult::instance();
    }

    /**
     * Browse Table (#151): one page of a table, read with the SELECT the app wrote (quoted names
     * from the schema, filter values in `$params`, bound), as an `sql` event. `$driver` is the
     * PDO driver it was written for (null for a callable connection, read without bound
     * values). The SELECT asks for one row more than `$pageSize`, so `truncated` says whether
     * another page follows (SqlTable).
     *
     * @param array<int, array<string, mixed>> $params
     */
    public static function browse(string $sql, ?string $connection, int $pageSize, ?string $driver, array $params = []): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        $pageSize = max(1, $pageSize);
        $names = self::connectionNames();
        [$source, $origin] = self::resolve($connection, $names);
        SqlTable::checkBrowse($sql, $source instanceof \PDO ? self::pdoDriverName($source) : null, $driver);
        self::refuseUnbindable($source, $origin, [['sql' => $sql, 'line' => 0, 'params' => $params]]);
        SqlCancel::report($source, $connection); // #144
        $started = hrtime(true);
        $result = $source instanceof \PDO ? self::runPdo($source, $sql, $pageSize, $params) : self::runCallable($source, $sql, $pageSize);
        $result['elapsedMs'] = round((hrtime(true) - $started) / 1e6, 3);
        $result['source'] = $origin;
        $result['maxRows'] = $pageSize;
        $result += self::connectionFields($connection);
        Channel::emit('sql', $result);

        return NoResult::instance();
    }

    /**
     * Apply in Browse Table (#151): the changes the user reviewed (UPDATE, INSERT, and DELETE
     * statements the app wrote, each with its bound `params`), in one transaction where each
     * must affect exactly one row (SqlTable::apply()). Emits an `sql` event per change and a
     * notice once committed; otherwise everything is rolled back and the error says which
     * change and why. A read-only saved connection (#139) refuses before connecting, and a
     * callable connection, which can't bind values, is refused.
     *
     * @param array<int, array<string, mixed>> $statements
     */
    public static function applyEdits(array $statements, ?string $connection, ?string $driver): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        $statements = array_values($statements);
        SqlTable::checkEdits($statements);
        self::refuseOnReadOnly($statements);
        [$source, $origin] = self::resolve($connection, []);
        if (!$source instanceof \PDO) {
            throw new SqlTableRefused('Browse Table changes rows only through a PDO connection, which binds values, and this connection (' . $origin . ') runs statements through a callable. Nothing ran.');
        }
        $driverName = self::pdoDriverName($source);
        SqlTable::checkDialect($driverName, $driver, 'Review Changes');
        SqlCancel::report($source, $connection, true); // #144
        $bind = static function (\PDOStatement $statement, array $params): void {
            self::bind($statement, $params);
        };
        foreach (SqlTable::apply($source, $driverName, $statements, $bind) as $result) {
            Channel::emit('sql', $result + ['source' => $origin] + self::connectionFields($connection));
        }
        Channel::emit('notice', ['message' => SqlTable::committed(count($statements))]);

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
     * A statement's `params` are its bound values (#145, see run()).
     *
     * @param array<int, array{sql: string, line: int, implicitCommit?: bool, params?: array<int, array<string, mixed>>}> $statements
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
        $driverName = $source instanceof \PDO ? self::pdoDriverName($source) : (WordPressDatabase::isWpdb($origin) ? 'mysql' : null);
        // #145: a statement whose values can't be bound refuses the whole script, before anything runs.
        self::refuseUnbindable($source, $origin, $statements);
        SqlCancel::report($source, $connection, $transaction); // #144
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
            $common = ['source' => $origin, 'maxRows' => $maxRows] + self::connectionFields($connection)
                + ['statement' => ['index' => $index + 1, 'count' => $count, 'line' => $line, 'text' => self::echoed($sql)]];
            $read = [];
            try {
                if ($index > 0) {
                    // #139: whatever the statement before did, the next one runs read-only.
                    SqlConnect::enforceReadOnly();
                }
                $params = isset($statement['params']) && is_array($statement['params']) ? $statement['params'] : [];
                if ($source instanceof \PDO) {
                    $results = self::runPdoSets($source, $sql, $maxRows, $params, $read); // #154
                } else {
                    $results = [self::runCallable($source, $sql, $maxRows) + ['readNs' => hrtime(true)]];
                }
            } catch (DriverFailure $failure) {
                throw $failure;
            } catch (\Throwable $error) {
                // #154: the result sets read before a later one failed still show.
                self::emitResults($read, false, $common, $started, $index === 0 ? $names : []);
                $notes = [];
                if ($transaction) {
                    $notes[] = self::rollBack($source, $index, $committedThrough);
                }
                if ($index + 1 < $count) {
                    $notes[] = ($index + 2 === $count ? 'Statement ' . $count . ' did' : 'Statements ' . ($index + 2) . '–' . $count . ' did') . ' not run.';
                }
                throw new SqlStatementFailed('Statement ' . ($index + 1) . ' of ' . $count . ' (line ' . $line . '): ' . $error->getMessage() . "\n\n" . implode(' ', $notes), 0, $error);
            }
            self::emitResults($results, true, $common, $started, $index === 0 ? $names : []);
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

    /**
     * Bound parameters (#145): refuses the run, before anything runs, when a statement has
     * values this connection can't bind. A callable connection (WordPress's $wpdb, Doctrine
     * without PDO, a driver's callable) has no binding API, and Runlet never writes values
     * into the SQL instead. MySQL's native prepares (which Runlet uses, so a second statement
     * can't slip through) refuse a name used more than once.
     *
     * @param \PDO|callable $source
     * @param array<int, array<string, mixed>> $statements
     */
    private static function refuseUnbindable($source, string $origin, array $statements): void
    {
        $count = count($statements);
        $driverName = $source instanceof \PDO ? self::pdoDriverName($source) : null;
        foreach (array_values($statements) as $index => $statement) {
            $params = isset($statement['params']) && is_array($statement['params']) ? $statement['params'] : [];
            if ($params === []) {
                continue;
            }
            $which = $count === 1 ? 'This statement has' : 'Statement ' . ($index + 1) . ' of ' . $count . ' (line ' . (int) $statement['line'] . ') has';
            if (!$source instanceof \PDO) {
                throw new SqlParametersRefused(WordPressDatabase::isWpdb($origin)
                    ? $which . ' placeholders, and this connection (' . $origin . ') runs statements through WordPress\'s $wpdb, without bound values. Runlet never writes values into the SQL, so nothing ran. Use $wpdb->prepare() in a PHP tab, or write the values into the statement yourself.'
                    : $which . ' placeholders, and this connection (' . $origin . ') runs statements through a callable, which can\'t bind values. Runlet never writes values into the SQL, so nothing ran. Return a PDO from the driver\'s sqlConnection() to bind values, run the query from a PHP tab, or write the values into the statement yourself.');
            }
            if ($driverName !== 'mysql') {
                continue;
            }
            foreach ($params as $param) {
                $uses = (int) ($param['uses'] ?? 1);
                if (isset($param['name']) && $uses > 1) {
                    throw new SqlParametersRefused($which . ' :' . $param['name'] . ' ' . $uses . ' times. MySQL and MariaDB can\'t bind one name in several places when the statement is prepared natively, as Runlet prepares it. Give each place its own name (:' . $param['name'] . ', :' . $param['name'] . '_2), or use ? placeholders. Nothing ran.');
                }
            }
        }
    }

    /**
     * Bound parameters (#145): each value with its PDO type. Text and decimals are PARAM_STR
     * (PDO has no decimal type, so a DECIMAL column keeps every digit), integers PARAM_INT,
     * booleans PARAM_BOOL, and NULL PARAM_NULL.
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
            $placeholder = isset($param['name']) ? ':' . $param['name'] : '?' . (int) ($param['position'] ?? 0);
            try {
                $bound = $statement->bindValue(isset($param['name']) ? ':' . $param['name'] : (int) ($param['position'] ?? 0), $value, $type);
            } catch (\PDOException $error) {
                throw new SqlParametersRefused('Runlet could not bind ' . $placeholder . ': ' . $error->getMessage() . ' PDO may read the statement differently than Runlet (a placeholder inside a string, a comment, or a quoted name).', 0, $error);
            }
            if ($bound === false) {
                throw new SqlParametersRefused('Runlet could not bind ' . $placeholder . '. PDO may read the statement differently than Runlet (a placeholder inside a string, a comment, or a quoted name).');
            }
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

                    if ($declaring === 'Runlet\Drivers\WordPressDriver') {
                        // #208: "WordPress (PDO from wp-config)" or "WordPress ($wpdb, because …)".
                        return [$source, WordPressDatabase::origin() ?? self::BUILTIN_SOURCES[$declaring]];
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

    /**
     * @param array<int, array<string, mixed>> $params Bound values (#145).
     * @param int $skip Rows to fetch and discard first (Load Next, #146).
     * @return array<string, mixed>
     */
    private static function runPdo(\PDO $pdo, string $sql, int $maxRows, array $params = [], int $skip = 0): array
    {
        $read = [];
        $results = self::runPdoSets($pdo, $sql, $maxRows, $params, $read, $skip, false);
        unset($results[0]['readNs']);

        return $results[0];
    }

    /**
     * Runs `$sql` and reads its result sets (#154): after the first, the next ones while the
     * driver has more (`PDOStatement::nextRowset()`: MySQL and MariaDB procedures, SQL Server
     * batches; SQLite and PostgreSQL return one). The row cap and the result size cap apply to
     * all of them together. A set without columns reports its affected rows. A last set that
     * has no columns and changed nothing, after others, is MySQL's status of the CALL itself
     * and is left out. `$read` holds the sets read so far, for the caller to show when a later
     * one fails.
     *
     * @param array<int, array<string, mixed>> $params Bound values (#145).
     * @param array<int, array<string, mixed>> $read
     * @param int $skip Rows of the first set to fetch and discard first (Load Next, #146).
     * @param bool $everySet false reads only the first set (Load Next pages single results).
     * @return array<int, array<string, mixed>> Each with `readNs` (hrtime when it was read).
     */
    private static function runPdoSets(\PDO $pdo, string $sql, int $maxRows, array $params, array &$read, int $skip = 0, bool $everySet = true): array
    {
        $driverName = self::pdoDriverName($pdo);
        $restore = [\PDO::ATTR_ERRMODE => $pdo->getAttribute(\PDO::ATTR_ERRMODE)];
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $attributes = [];
        if ($driverName === 'mysql' || $params !== []) {
            // Native prepares, so MySQL refuses several statements in one run, and bound values
            // (#145) go to the database apart from the SQL rather than being quoted into it by
            // PDO (drivers without the setting, such as SQLite, always bind natively).
            $attributes[\PDO::ATTR_EMULATE_PREPARES] = false;
        }
        if ($driverName === 'mysql') {
            // Unbuffered, so a large result is not held in memory beyond the rows Runlet keeps.
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
                // The attribute isn't supported here: keep the connection's setting.
            }
        }
        try {
            $statement = $pdo->prepare($sql);
            self::bind($statement, $params);
            $statement->execute();
            $budget = ['rows' => $maxRows, 'bytes' => 0];
            do {
                $set = self::readSet($statement, $driverName, $budget, $read === [] ? $skip : 0, $read !== []);
                $set['readNs'] = hrtime(true);
                $read[] = $set;
            } while ($everySet && self::nextRowset($statement, $driverName));
            if (isset($set['columns'])) {
                $statement->closeCursor();
            }
            $last = $read[count($read) - 1];
            if (count($read) > 1 && !isset($last['columns']) && (int) ($last['affectedRows'] ?? 0) === 0) {
                array_pop($read);
            }

            return $read;
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

    /**
     * One result set of `$statement`: its columns and rows within `$budget` (rows left, bytes
     * used by the sets before it), or the rows it affected.
     *
     * @param array{rows: int, bytes: int} $budget
     * @return array<string, mixed>
     */
    private static function readSet(\PDOStatement $statement, ?string $driverName, array &$budget, int $skip, bool $later): array
    {
        $count = $statement->columnCount();
        if ($count > 0 && $later) {
            // After a set with columns, MySQL keeps reporting its column count for a set that
            // has none (a procedure's UPDATE, or the CALL's own status); such a set has no meta.
            try {
                $meta = $statement->getColumnMeta(0);
            } catch (\Throwable $error) {
                $meta = false;
            }
            if (!is_array($meta)) {
                $count = 0;
            }
        }
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
        while ($skip > 0 && $statement->fetch(\PDO::FETCH_NUM) !== false) {
            $skip--;
        }
        while (($row = $statement->fetch(\PDO::FETCH_NUM)) !== false) {
            if (count($rows) >= $budget['rows']) {
                $truncation = 'rows';
                break;
            }
            if ($budget['bytes'] + $bytes >= self::MAX_RESULT_BYTES) {
                $truncation = 'bytes';
                break;
            }
            $cells = [];
            foreach (array_slice($row, 0, count($columns)) as $value) {
                $cells[] = self::cell($value, $bytes);
            }
            $rows[] = $cells;
        }
        $budget['rows'] = max(0, $budget['rows'] - count($rows));
        $budget['bytes'] += $bytes;

        return array_filter([
            'driver' => $driverName,
            'columns' => $columns,
            'rows' => $rows,
            'truncated' => $truncation !== null ? true : null,
            'truncation' => $truncation,
            'omittedColumns' => $count > count($columns) ? $count - count($columns) : null,
            'bytes' => $bytes,
        ], static function ($value): bool {
            return $value !== null;
        });
    }

    /**
     * Moves to the statement's next result set (#154). SQLite and PostgreSQL have one, and
     * keep today's behaviour (nothing is asked); a driver without multiple result sets
     * (SQLSTATE IM001) has no more. A later statement of a procedure that failed throws.
     */
    private static function nextRowset(\PDOStatement $statement, ?string $driverName): bool
    {
        if ($driverName === null || in_array($driverName, ['sqlite', 'sqlite2', 'pgsql'], true)) {
            return false;
        }
        try {
            return $statement->nextRowset();
        } catch (\PDOException $error) {
            if ((string) $error->getCode() === 'IM001') {
                return false;
            }
            throw $error;
        }
    }

    /**
     * @param int $skip Rows to pass over first (Load Next, #146).
     * @return array<string, mixed>
     */
    private static function runCallable(callable $run, string $sql, int $maxRows, int $skip = 0): array
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
            if ($skip > 0) {
                $skip--;
                continue;
            }
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
            'bytes' => $bytes,
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
