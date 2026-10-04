<?php

declare(strict_types=1);

/*
 * Stop cancels an SQL tab's statement on the database server (#144).
 *
 * A run reports its connection's server-side session as an `sqlSession` event right after
 * connecting, before the statement runs (report()). On Stop, the app starts a second, short
 * runner on the same target with the same connection, which calls SqlTab::cancel() and so
 * cancel(): it checks that its connection reached the same server, that the session still runs
 * something, sends the one cancel statement for the dialect, and watches the statement end. It
 * emits an `sqlCancel` event. Then the app stops the first runner's process, as Stop always did.
 *
 * Only Runlet's own statements run here: KILL QUERY <id> (MySQL, MariaDB), SELECT
 * pg_cancel_backend(<pid>) (PostgreSQL), KILL <spid> (SQL Server). They are allowed in a
 * read-only session (#139). No event carries credentials.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class SqlCancel
{
    /** How long cancel() watches the statement end after the server took the cancel. */
    private const VERIFY_MS = 1500;
    /** Between two looks at the session. */
    private const POLL_MS = 50;

    /**
     * Emits the `sqlSession` event for `$source` when it is a PDO connection to a server Runlet
     * can cancel on. Never fails the run: a session that can't be read just isn't reported, and
     * Stop then only ends the runner, as before.
     *
     * @param \PDO|callable $source
     */
    public static function report($source, ?string $connection, bool $transaction = false): void
    {
        if (!$source instanceof \PDO) {
            return; // A callable connection: no session Runlet can name.
        }
        $identity = self::identify($source);
        if ($identity === null) {
            return;
        }
        Channel::emit('sqlSession', array_filter([
            'driver' => $identity['driver'],
            'id' => $identity['id'],
            'connection' => SqlConnect::isConfigured() ? null : $connection,
            'saved' => SqlConnect::isConfigured() ? true : null,
            'transaction' => $transaction ? true : null,
            'server' => $identity['server'],
        ], static function ($value): bool {
            return $value !== null;
        }));
    }

    /**
     * The cancel statement of `$session` in `$dialect`; null for dialects without one.
     */
    public static function statement(string $dialect, int $session): ?string
    {
        if ($session <= 0) {
            return null;
        }
        switch ($dialect) {
            case 'mysql':
                return 'KILL QUERY ' . $session;
            case 'pgsql':
                return 'SELECT pg_cancel_backend(' . $session . ')';
            case 'sqlsrv':
                return 'KILL ' . $session;
            default:
                return null;
        }
    }

    /**
     * Cancels `$session`'s statement through `$source` (the same connection, opened again) and
     * returns the `sqlCancel` event: `outcome` (cancelled, stillRunning, alreadyEnded, idle,
     * refused, failed), `detail`, `state`, `verified`, `elapsedMs`.
     *
     * @param \PDO|callable $source
     * @return array<string, mixed>
     */
    public static function cancel($source, string $origin, string $dialect, int $session, string $statement, string $server): array
    {
        $started = hrtime(true);
        $done = static function (string $outcome, array $fields = []) use ($dialect, $session, $statement, $started): array {
            return array_filter([
                'outcome' => $outcome,
                'driver' => $dialect,
                'session' => $session,
                'statement' => $statement,
                'detail' => $fields['detail'] ?? null,
                'state' => $fields['state'] ?? null,
                'verified' => $fields['verified'] ?? null,
                'elapsedMs' => round((hrtime(true) - $started) / 1e6, 3),
            ], static function ($value): bool {
                return $value !== null;
            });
        };
        if (!$source instanceof \PDO) {
            return $done('failed', ['detail' => 'the connection (' . $origin . ') is no longer a PDO connection, so Runlet has nothing to send the cancel through']);
        }
        $pdo = $source;
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $identity = self::identify($pdo);
        if ($identity === null || self::dialect($identity['driver']) !== $dialect) {
            $actual = $identity === null ? self::driverName($pdo) : $identity['driver'];

            return $done('failed', ['detail' => 'the connection is ' . ($actual === null ? 'of an unknown kind' : 'a ' . $actual . ' connection') . ' now, and the statement ran on ' . $dialect]);
        }
        if (self::statement($dialect, $session) !== $statement) {
            return $done('refused', ['detail' => 'Runlet sends only its own cancel statement for session ' . $session]);
        }
        if ($identity['id'] === $session) {
            return $done('refused', ['detail' => 'the second connection got session ' . $session . ' itself']);
        }
        if ($server !== '' && $identity['server'] !== null && $identity['server'] !== $server) {
            return $done('refused', ['detail' => 'the second connection reached another database server (a list of hosts, a load balancer, or a failover?), so Runlet sent nothing there']);
        }
        $before = self::activity($pdo, $dialect, $session);
        if ($before !== null && $before['gone'] && $dialect === 'mysql') {
            // MySQL shows only the user's own threads without the PROCESS privilege: KILL QUERY
            // says whether the thread exists (1094) and whether this user may cancel it (1095).
            $before = null;
        }
        if ($before !== null) {
            if ($before['gone']) {
                return $done('alreadyEnded');
            }
            if ($before['otherUser']) {
                return $done('refused', ['detail' => 'session ' . $session . ' belongs to another database user now']);
            }
            if ($before['running'] === false) {
                return $done('idle');
            }
        }
        try {
            if ($dialect === 'pgsql') {
                $result = $pdo->query($statement);
                $sent = $result === false ? false : $result->fetchColumn();
                if (!in_array($sent, [true, 1, '1', 't', 'true'], true)) {
                    // PostgreSQL: false (with a warning) when no backend has the pid.
                    return $done('alreadyEnded');
                }
            } else {
                $pdo->exec($statement);
            }
        } catch (\PDOException $error) {
            return self::refusal($done, $dialect, $session, $error);
        }
        if ($before === null) {
            // The session isn't visible to this user (another user's MySQL thread, SQL Server
            // without VIEW SERVER STATE): the server took the cancel; Runlet can't watch it end.
            return $done('cancelled', ['verified' => false]);
        }
        $deadline = hrtime(true) + self::VERIFY_MS * 1000000;
        $now = $before;
        while (true) {
            $now = self::activity($pdo, $dialect, $session);
            if ($now === null) {
                return $done('cancelled', ['verified' => false]);
            }
            if ($now['gone'] || $now['running'] === false || !self::same($before, $now)) {
                return $done('cancelled', ['verified' => true]);
            }
            if (hrtime(true) >= $deadline) {
                break;
            }
            usleep(self::POLL_MS * 1000);
        }

        return $done('stillRunning', ['state' => $now['state'] ?? null]);
    }

    /**
     * Why the database refused the cancel, as an outcome: the session had ended, or the user
     * may not cancel it.
     *
     * @param callable(string, array<string, mixed>=): array<string, mixed> $done
     * @return array<string, mixed>
     */
    private static function refusal(callable $done, string $dialect, int $session, \PDOException $error): array
    {
        $code = is_array($error->errorInfo) ? ($error->errorInfo[1] ?? null) : null;
        $state = is_array($error->errorInfo) ? (string) ($error->errorInfo[0] ?? '') : (string) $error->getCode();
        $message = self::databaseMessage($error);
        if ($dialect === 'mysql') {
            if ((int) $code === 1094) {
                return $done('alreadyEnded'); // Unknown thread id.
            }
            if ((int) $code === 1095) {
                return $done('refused', ['detail' => 'the database user may not cancel session ' . $session . ' (' . $message . '); cancelling another user\'s statement needs the CONNECTION_ADMIN or SUPER privilege']);
            }
        } elseif ($dialect === 'pgsql') {
            if ($state === '42501') {
                return $done('refused', ['detail' => 'the database user may not cancel session ' . $session . ' (' . $message . '); pg_cancel_backend needs the same role, or membership in pg_signal_backend']);
            }
        } elseif ($dialect === 'sqlsrv') {
            if ((int) $code === 6106) {
                return $done('alreadyEnded'); // Process ID is not an active process ID.
            }
            if ((int) $code === 6102) {
                return $done('refused', ['detail' => 'the database user may not cancel session ' . $session . ' (' . $message . '); SQL Server\'s KILL needs the ALTER ANY CONNECTION permission']);
            }
        }

        return $done('failed', ['detail' => $message]);
    }

    /** The database's own words, without PDO's SQLSTATE prefix. */
    private static function databaseMessage(\PDOException $error): string
    {
        $info = $error->errorInfo;
        if (is_array($info) && isset($info[2]) && is_string($info[2]) && $info[2] !== '') {
            return trim(preg_replace('/^ERROR:\s+/', '', $info[2]) ?? $info[2]);
        }

        return $error->getMessage();
    }

    /**
     * This connection's session id, its PDO driver, and a fingerprint of its server; null for
     * drivers Runlet can't cancel on (SQLite needs nothing: the database is in this process).
     *
     * @return array{driver: string, id: int, server: string|null}|null
     */
    private static function identify(\PDO $pdo): ?array
    {
        $driver = self::driverName($pdo);
        $queries = [
            'mysql' => 'SELECT CONNECTION_ID(), @@hostname, @@port',
            'pgsql' => 'SELECT pg_backend_pid(), pg_postmaster_start_time()::text, inet_server_port()',
            'sqlsrv' => 'SELECT @@SPID, @@SERVERNAME',
        ];
        $dialect = self::dialect($driver);
        if ($driver === null || $dialect === null || !isset($queries[$dialect])) {
            return null;
        }
        $mode = null;
        try {
            $mode = $pdo->getAttribute(\PDO::ATTR_ERRMODE);
            $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
            $statement = $pdo->query($queries[$dialect]);
            $row = $statement === false ? false : $statement->fetch(\PDO::FETCH_NUM);
            if ($statement !== false) {
                $statement->closeCursor();
            }
        } catch (\Throwable $error) {
            $row = false;
        } finally {
            if ($mode !== null) {
                try {
                    $pdo->setAttribute(\PDO::ATTR_ERRMODE, $mode);
                } catch (\Throwable $error) {
                    // Keep going; the run sets its own error mode for the statement.
                }
            }
        }
        if (!is_array($row) || !isset($row[0]) || (int) $row[0] <= 0) {
            return null;
        }
        $parts = array_map(static function ($part): string {
            return $part === null ? '' : (string) $part;
        }, array_slice($row, 1));

        return ['driver' => $driver, 'id' => (int) $row[0], 'server' => substr(sha1($dialect . '|' . implode('|', $parts)), 0, 16)];
    }

    /**
     * What `$session` is doing, as far as this user may see: `gone` (no such session),
     * `running` (null when unknown), `otherUser`, `state`, and what identifies the statement
     * (`since`, `text`). Null when Runlet can't look (no view, no rights, SQL Server).
     *
     * @return array{gone: bool, running: bool|null, otherUser: bool, state: string|null, since: string|null, text: string|null}|null
     */
    private static function activity(\PDO $pdo, string $dialect, int $session): ?array
    {
        try {
            if ($dialect === 'mysql') {
                $statement = $pdo->prepare('SELECT COMMAND, TIME, STATE, INFO, USER, SUBSTRING_INDEX(USER(), \'@\', 1) FROM information_schema.PROCESSLIST WHERE ID = ?');
                $statement->execute([$session]);
                $row = $statement->fetch(\PDO::FETCH_NUM);
                $statement->closeCursor();
                if (!is_array($row)) {
                    // Gone, or (without the PROCESS privilege) another user's thread: cancel()
                    // tells them apart.
                    return ['gone' => true, 'running' => null, 'otherUser' => false, 'state' => null, 'since' => null, 'text' => null];
                }
                $command = (string) $row[0];

                return [
                    'gone' => false,
                    'running' => $command !== 'Sleep',
                    'otherUser' => (string) $row[4] !== '' && (string) $row[5] !== '' && (string) $row[4] !== (string) $row[5],
                    'state' => trim($command . ($row[2] !== null && (string) $row[2] !== '' ? ', ' . $row[2] : '')),
                    'since' => (string) $row[1],
                    'text' => $row[3] === null ? null : (string) $row[3],
                ];
            }
            if ($dialect === 'pgsql') {
                $statement = $pdo->prepare('SELECT state, query_start::text, usename, session_user FROM pg_stat_activity WHERE pid = ?');
                $statement->execute([$session]);
                $row = $statement->fetch(\PDO::FETCH_NUM);
                $statement->closeCursor();
                if (!is_array($row)) {
                    return ['gone' => true, 'running' => null, 'otherUser' => false, 'state' => null, 'since' => null, 'text' => null];
                }
                $state = $row[0] === null ? null : (string) $row[0];

                return [
                    'gone' => false,
                    // Null for another role's session: its state isn't shown.
                    'running' => $state === null ? null : $state === 'active',
                    'otherUser' => $row[2] !== null && (string) $row[2] !== (string) $row[3],
                    'state' => $state,
                    'since' => $row[1] === null ? null : (string) $row[1],
                    'text' => null,
                ];
            }
        } catch (\Throwable $error) {
            return null;
        }

        return null;
    }

    /**
     * Whether `$now` is still the statement `$before` saw: PostgreSQL's query start, or MySQL's
     * statement text with a time that didn't start over.
     *
     * @param array<string, mixed> $before
     * @param array<string, mixed> $now
     */
    private static function same(array $before, array $now): bool
    {
        if ($before['text'] !== null || $now['text'] !== null) {
            return $before['text'] === $now['text'] && (int) $now['since'] >= (int) $before['since'];
        }

        return $before['since'] === $now['since'];
    }

    private static function driverName(\PDO $pdo): ?string
    {
        try {
            return (string) $pdo->getAttribute(\PDO::ATTR_DRIVER_NAME);
        } catch (\Throwable $error) {
            return null;
        }
    }

    /** `mysql`, `pgsql`, or `sqlsrv` (also through dblib); null for the rest. */
    private static function dialect(?string $driver): ?string
    {
        switch ($driver) {
            case 'mysql':
            case 'pgsql':
                return $driver;
            case 'sqlsrv':
            case 'dblib':
                return 'sqlsrv';
            default:
                return null;
        }
    }
}
