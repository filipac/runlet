<?php

declare(strict_types=1);

/*
 * The Database pane's Server section (#150): what the server of an SQL tab's connection is,
 * how big its database and largest tables are, and which sessions it has, read on demand in a
 * fresh runner; and a confirmed Cancel Query or Kill Session on one of those sessions.
 *
 * read() reads only the catalog and the server's status, never rows of tables:
 *  - overview: the server and its version, the current database and user, uptime, TLS;
 *  - sizes: the database's size and its largest tables with data and index sizes
 *    (information_schema.TABLES on MySQL and MariaDB, pg_database_size()/pg_table_size()/
 *    pg_indexes_size()/pg_total_relation_size() on PostgreSQL, the dbstat table or the file's
 *    page count on SQLite);
 *  - sessions: information_schema.PROCESSLIST (MySQL, MariaDB) or pg_stat_activity
 *    (PostgreSQL), with what this user may see. SQLite has no sessions.
 * Each part fails on its own (a missing privilege), so the others still show.
 *
 * act() sends one of Runlet's own statements: KILL QUERY <id> or KILL <id> (MySQL, MariaDB),
 * SELECT pg_cancel_backend(<pid>) or SELECT pg_terminate_backend(<pid>) (PostgreSQL), after
 * checking that its connection reached the same server the list came from (#144's server
 * fingerprint), that the session isn't the one the list was read with nor its own, and that
 * the session is still the one listed (its user; PostgreSQL's backend start, as pids are
 * reused). Then it watches the statement or the session end. They are allowed in a read-only
 * session (#139): they change no data. SQL Server and callable connections aren't supported.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class SqlServerInfo
{
    /** Largest tables reported. */
    public const MAX_TABLES = 20;
    /** Sessions reported at most. */
    public const MAX_SESSIONS = 200;
    /** Bytes kept of one session's statement, and of all of them together. */
    public const MAX_QUERY_BYTES = 4096;
    public const MAX_QUERIES_BYTES = 1048576;
    /** How long act() watches the statement or session end. */
    private const VERIFY_MS = 2000;
    private const POLL_MS = 50;
    /**
     * PostgreSQL's client sessions: `client backend`, or (another role's, whose backend type
     * PostgreSQL hides without pg_read_all_stats) a session with a database and a role.
     */
    private const PG_CLIENTS = "(backend_type = 'client backend' OR (backend_type IS NULL AND datid IS NOT NULL AND usesysid IS NOT NULL))";

    /**
     * The parts of the server report asked for (`overview`, `sizes`, `sessions`), as the
     * `sqlServer` event's fields; `errors` holds the parts that failed, by name.
     *
     * @param \PDO|callable $source
     * @param string[] $parts
     * @return array<string, mixed>
     */
    public static function read($source, string $origin, ?string $driverName, array $parts): array
    {
        $parts = array_values(array_intersect(['overview', 'sizes', 'sessions'], $parts));
        if ($parts === []) {
            $parts = ['overview', 'sizes', 'sessions'];
        }
        $pdo = self::pdo($source, $origin, $driverName, 'read server details');
        $dialect = self::dialect($driverName);
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $result = ['dialect' => $dialect, 'parts' => $parts];
        $identity = $dialect === 'sqlite' ? null : SqlCancel::identify($pdo);
        if ($identity !== null) {
            $result['sessionId'] = $identity['id'];
            $result['server'] = $identity['server'];
        }
        $errors = [];
        foreach ($parts as $part) {
            try {
                if ($part === 'overview') {
                    $result['overview'] = self::overview($pdo, $dialect);
                } elseif ($part === 'sizes') {
                    $result['sizes'] = self::sizes($pdo, $dialect);
                } else {
                    $result['sessions'] = self::sessions($pdo, $dialect, $identity === null ? 0 : $identity['id']);
                }
            } catch (DriverFailure $failure) {
                throw $failure;
            } catch (\Throwable $error) {
                $errors[$part] = self::message($error);
            }
        }
        if ($errors !== []) {
            $result['errors'] = $errors;
        }

        return $result;
    }

    /**
     * Runlet's statement for `$action` (`cancel`, `kill`) on `$session`; null where there is none.
     */
    public static function statement(string $action, string $dialect, int $session): ?string
    {
        if ($session <= 0) {
            return null;
        }
        if ($action === 'cancel') {
            return in_array($dialect, ['mysql', 'pgsql'], true) ? SqlCancel::statement($dialect, $session) : null;
        }
        if ($action === 'kill') {
            if ($dialect === 'mysql') {
                return 'KILL ' . $session;
            }
            if ($dialect === 'pgsql') {
                return 'SELECT pg_terminate_backend(' . $session . ')';
            }
        }

        return null;
    }

    /**
     * Cancel Query or Kill Session on `$session`, which the list read with session `$listedBy`
     * on server `$server` showed for user `$user` (and, on PostgreSQL, started at `$started`).
     * Returns the `sqlServerAction` event: `outcome` (cancelled, killed, stillRunning,
     * alreadyEnded, idle, refused, failed), `detail`, `state`, `verified`, `elapsedMs`.
     *
     * @param \PDO|callable $source
     * @return array<string, mixed>
     */
    public static function act($source, string $origin, ?string $driverName, string $action, string $dialect, int $session, string $statement, string $server, int $listedBy, string $user, string $started): array
    {
        $begun = hrtime(true);
        $done = static function (string $outcome, array $fields = []) use ($action, $dialect, $session, $statement, $begun): array {
            return array_filter([
                'action' => $action,
                'outcome' => $outcome,
                'driver' => $dialect,
                'session' => $session,
                'statement' => $statement,
                'detail' => $fields['detail'] ?? null,
                'state' => $fields['state'] ?? null,
                'verified' => $fields['verified'] ?? null,
                'elapsedMs' => round((hrtime(true) - $begun) / 1e6, 3),
            ], static function ($value): bool {
                return $value !== null;
            });
        };
        if (!in_array($action, ['cancel', 'kill'], true) || self::statement($action, $dialect, $session) !== $statement) {
            return $done('refused', ['detail' => 'Runlet sends only its own ' . ($action === 'kill' ? 'kill' : 'cancel') . ' statement for session ' . $session]);
        }
        if (!$source instanceof \PDO) {
            return $done('failed', ['detail' => 'the connection (' . $origin . ') is a callable, so Runlet has nothing to send the statement through']);
        }
        $pdo = $source;
        $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $identity = SqlCancel::identify($pdo);
        if ($identity === null || self::dialect($identity['driver']) !== $dialect) {
            return $done('failed', ['detail' => 'the connection is ' . ($driverName === null ? 'of an unknown kind' : 'a ' . $driverName . ' connection') . ' now, and the session was listed on ' . $dialect]);
        }
        if ($listedBy > 0 && $session === $listedBy) {
            return $done('refused', ['detail' => 'session ' . $session . ' is the one the panel read the list with']);
        }
        if ($identity['id'] === $session) {
            return $done('refused', ['detail' => 'session ' . $session . ' is this runner\'s own connection']);
        }
        if ($server !== '' && $identity['server'] !== null && $identity['server'] !== $server) {
            return $done('refused', ['detail' => 'this connection reached another database server than the list came from (a list of hosts, a load balancer, or a failover?), so Runlet sent nothing there']);
        }
        $before = self::session($pdo, $dialect, $session);
        if ($before === null) {
            // MySQL without the PROCESS privilege shows only this user's own threads: KILL says
            // whether the thread exists (1094) and whether this user may end it (1095).
            if ($dialect === 'pgsql') {
                return $done('alreadyEnded');
            }
            $self = self::currentUserName($pdo);
            if ($user === '' || $self === null || $self === $user) {
                return $done('alreadyEnded');
            }
        } else {
            if ($user !== '' && $before['user'] !== null && $before['user'] !== $user) {
                return $done('refused', ['detail' => 'session ' . $session . ' belongs to ' . $before['user'] . ' now, not ' . $user . ', so it isn\'t the session the panel listed']);
            }
            if ($dialect === 'pgsql' && $started !== '' && $before['started'] !== null && $before['started'] !== $started) {
                return $done('refused', ['detail' => 'process ' . $session . ' is another session now (it started at ' . $before['started'] . ', the listed one at ' . $started . ')']);
            }
            if ($action === 'cancel' && $before['running'] === false) {
                return $done('idle', ['state' => $before['state']]);
            }
        }
        try {
            if ($dialect === 'pgsql') {
                $sent = $pdo->query($statement);
                $answer = $sent === false ? false : $sent->fetchColumn();
                if (!in_array($answer, [true, 1, '1', 't', 'true'], true)) {
                    return $done('alreadyEnded'); // No backend has the pid (any more).
                }
            } else {
                $pdo->exec($statement);
            }
        } catch (\PDOException $error) {
            return self::refusal($done, $action, $dialect, $session, $error);
        }
        if ($before === null) {
            return $done($action === 'kill' ? 'killed' : 'cancelled', ['verified' => false]);
        }
        $deadline = hrtime(true) + self::VERIFY_MS * 1000000;
        $now = $before;
        while (true) {
            usleep(self::POLL_MS * 1000);
            $now = self::session($pdo, $dialect, $session);
            if ($now === null) {
                return $done($action === 'kill' ? 'killed' : 'cancelled', ['verified' => true]);
            }
            if ($action === 'cancel' && ($now['running'] === false || !self::sameStatement($before, $now))) {
                return $done('cancelled', ['verified' => true]);
            }
            if (hrtime(true) >= $deadline) {
                break;
            }
        }

        return $done('stillRunning', ['state' => $now['state']]);
    }

    /**
     * The connection as a PDO, or why the panel can't use it.
     *
     * @param \PDO|callable $source
     */
    private static function pdo($source, string $origin, ?string $driverName, string $what): \PDO
    {
        if (!$source instanceof \PDO) {
            throw new SqlUnavailable('Runlet can\'t ' . $what . ' here: this connection is a callable from ' . $origin . ', so Runlet doesn\'t know its database and can\'t send its own queries through it. The server panel needs a PDO connection (MySQL, MariaDB, PostgreSQL, or SQLite).');
        }
        $dialect = self::dialect($driverName);
        if ($dialect === null) {
            if ($driverName === 'sqlsrv' || $driverName === 'dblib') {
                throw new SqlUnavailable('Runlet\'s server panel doesn\'t support SQL Server yet. Use sys.dm_exec_sessions and sp_who2 in a query, or your database tool.');
            }
            throw new SqlUnavailable('Runlet can\'t ' . $what . ' on ' . ($driverName ?? 'this kind of') . ' connections: the server panel reads MySQL, MariaDB, PostgreSQL, and SQLite.');
        }

        return $source;
    }

    /** `mysql`, `pgsql`, or `sqlite`; null for the rest. */
    private static function dialect(?string $driver): ?string
    {
        switch ($driver) {
            case 'mysql':
            case 'pgsql':
            case 'sqlite':
                return $driver;
            case 'sqlite2':
                return 'sqlite';
            default:
                return null;
        }
    }

    /**
     * The server, its version, the current database and user, uptime, and TLS.
     *
     * @return array<string, mixed>
     */
    private static function overview(\PDO $pdo, string $dialect): array
    {
        $version = (string) $pdo->getAttribute(\PDO::ATTR_SERVER_VERSION);
        if ($dialect === 'mysql') {
            $row = $pdo->query('SELECT VERSION(), DATABASE(), CURRENT_USER(), @@version_comment')->fetch(\PDO::FETCH_NUM);
            $status = self::status($pdo, ['Uptime', 'Threads_connected', 'Ssl_version', 'Ssl_cipher'], 'GLOBAL');
            $session = self::status($pdo, ['Ssl_version', 'Ssl_cipher'], 'SESSION');
            $full = is_array($row) && $row[0] !== null ? (string) $row[0] : $version;
            $cipher = (string) ($session['Ssl_cipher'] ?? '');
            $mariadb = stripos($full, 'mariadb') !== false || (is_array($row) && stripos((string) $row[3], 'mariadb') !== false);

            return self::filtered([
                'product' => $mariadb ? 'MariaDB' : 'MySQL',
                'version' => self::number($full),
                'versionText' => self::bounded($full . (is_array($row) && $row[3] !== null && (string) $row[3] !== '' ? ' (' . $row[3] . ')' : ''), 200),
                'database' => is_array($row) && $row[1] !== null ? (string) $row[1] : null,
                'user' => is_array($row) && $row[2] !== null ? (string) $row[2] : null,
                'uptimeSeconds' => isset($status['Uptime']) ? (int) $status['Uptime'] : null,
                'connections' => isset($status['Threads_connected']) ? (int) $status['Threads_connected'] : null,
                'tls' => $session === [] ? null : $cipher !== '',
                'tlsVersion' => $cipher === '' ? null : (string) ($session['Ssl_version'] ?? ''),
                'tlsCipher' => $cipher === '' ? null : $cipher,
            ]);
        }
        if ($dialect === 'pgsql') {
            $row = $pdo->query("SELECT version(), current_setting('server_version'), current_database(), current_user, EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time()))::bigint, (SELECT COUNT(*) FROM pg_stat_activity WHERE " . self::PG_CLIENTS . ')')->fetch(\PDO::FETCH_NUM);
            $tls = [];
            try {
                $ssl = $pdo->query('SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid()')->fetch(\PDO::FETCH_NUM);
                if (is_array($ssl)) {
                    $on = self::truthy($ssl[0]);
                    $tls = ['tls' => $on, 'tlsVersion' => $on ? (string) $ssl[1] : null, 'tlsCipher' => $on ? (string) $ssl[2] : null];
                }
            } catch (\Throwable $error) {
                $tls = [];
            }

            return self::filtered([
                'product' => 'PostgreSQL',
                'version' => self::number(is_array($row) ? (string) $row[1] : $version),
                'versionText' => is_array($row) ? self::bounded((string) $row[0], 200) : $version,
                'database' => is_array($row) ? (string) $row[2] : null,
                'user' => is_array($row) ? (string) $row[3] : null,
                'uptimeSeconds' => is_array($row) && $row[4] !== null ? (int) $row[4] : null,
                'connections' => is_array($row) && $row[5] !== null ? (int) $row[5] : null,
            ] + $tls);
        }
        $file = null;
        foreach ($pdo->query('PRAGMA database_list')->fetchAll(\PDO::FETCH_ASSOC) as $database) {
            if (($database['name'] ?? '') === 'main') {
                $file = (string) ($database['file'] ?? '');
            }
        }

        return self::filtered([
            'product' => 'SQLite',
            'version' => self::number((string) $pdo->query('SELECT sqlite_version()')->fetchColumn()),
            'database' => $file === null || $file === '' ? ':memory:' : $file,
            'journalMode' => (string) $pdo->query('PRAGMA journal_mode')->fetchColumn(),
        ]);
    }

    /**
     * The database's size and its largest tables (data, indexes, total, estimated rows).
     *
     * @return array<string, mixed>
     */
    private static function sizes(\PDO $pdo, string $dialect): array
    {
        if ($dialect === 'mysql') {
            $database = $pdo->query('SELECT DATABASE()')->fetchColumn();
            if ($database === null || $database === false) {
                return ['tables' => [], 'how' => 'information_schema.TABLES', 'notes' => ['The connection has no current database, so there are no table sizes to read.']];
            }
            $total = $pdo->query("SELECT SUM(DATA_LENGTH), SUM(INDEX_LENGTH), SUM(DATA_FREE), SUM(TABLE_TYPE <> 'VIEW'), SUM(TABLE_TYPE = 'VIEW') FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()")->fetch(\PDO::FETCH_NUM);
            $statement = $pdo->query("SELECT TABLE_NAME, ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, DATA_FREE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE <> 'VIEW' ORDER BY COALESCE(DATA_LENGTH, 0) + COALESCE(INDEX_LENGTH, 0) DESC, TABLE_NAME LIMIT " . self::MAX_TABLES);
            $tables = [];
            $innodb = false;
            while (($row = $statement->fetch(\PDO::FETCH_NUM)) !== false) {
                $innodb = $innodb || strcasecmp((string) $row[1], 'InnoDB') === 0;
                $tables[] = self::filtered([
                    'name' => (string) $row[0],
                    'engine' => $row[1] === null ? null : (string) $row[1],
                    'rows' => $row[2] === null ? null : (int) $row[2],
                    'dataBytes' => $row[3] === null ? null : (int) $row[3],
                    'indexBytes' => $row[4] === null ? null : (int) $row[4],
                    'totalBytes' => $row[3] === null && $row[4] === null ? null : (int) $row[3] + (int) $row[4],
                    'freeBytes' => $row[5] === null || (int) $row[5] === 0 ? null : (int) $row[5],
                ]);
            }
            $statement->closeCursor();
            $data = is_array($total) ? (int) $total[0] : 0;
            $indexes = is_array($total) ? (int) $total[1] : 0;

            return self::filtered([
                'database' => (string) $database,
                'databaseBytes' => $data + $indexes,
                'dataBytes' => $data,
                'indexBytes' => $indexes,
                'freeBytes' => is_array($total) && (int) $total[2] > 0 ? (int) $total[2] : null,
                'tableCount' => is_array($total) ? (int) $total[3] : count($tables),
                'viewCount' => is_array($total) && (int) $total[4] > 0 ? (int) $total[4] : null,
                'tables' => $tables,
                'how' => 'information_schema.TABLES',
                'estimated' => $innodb ? true : null,
                'notes' => $innodb ? ['InnoDB sizes and row counts are the server\'s estimates (ANALYZE TABLE refreshes them).'] : null,
            ]);
        }
        if ($dialect === 'pgsql') {
            $database = $pdo->query('SELECT current_database(), pg_database_size(current_database())')->fetch(\PDO::FETCH_NUM);
            $where = "c.relkind IN ('r', 'p', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_toast%' AND n.nspname NOT LIKE 'pg\\_temp%'";
            $counts = $pdo->query("SELECT COUNT(*) FILTER (WHERE c.relkind IN ('r', 'p')), COUNT(*) FILTER (WHERE c.relkind = 'm') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE " . $where)->fetch(\PDO::FETCH_NUM);
            $statement = $pdo->query('SELECT n.nspname, c.relname, c.relkind, c.reltuples::bigint, pg_table_size(c.oid), pg_indexes_size(c.oid), pg_total_relation_size(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE ' . $where . ' ORDER BY pg_total_relation_size(c.oid) DESC, n.nspname, c.relname LIMIT ' . self::MAX_TABLES);
            $tables = [];
            while (($row = $statement->fetch(\PDO::FETCH_NUM)) !== false) {
                $tables[] = self::filtered([
                    'name' => (string) $row[1],
                    'schema' => (string) $row[0],
                    'kind' => $row[2] === 'p' ? 'partitioned table' : ($row[2] === 'm' ? 'materialized view' : null),
                    // -1: never analyzed (PostgreSQL 14 and later).
                    'rows' => $row[3] === null || (int) $row[3] < 0 ? null : (int) $row[3],
                    'dataBytes' => (int) $row[4],
                    'indexBytes' => (int) $row[5],
                    'totalBytes' => (int) $row[6],
                ]);
            }
            $statement->closeCursor();

            return self::filtered([
                'database' => is_array($database) ? (string) $database[0] : null,
                'databaseBytes' => is_array($database) ? (int) $database[1] : null,
                'tableCount' => is_array($counts) ? (int) $counts[0] : count($tables),
                'viewCount' => is_array($counts) && (int) $counts[1] > 0 ? (int) $counts[1] : null,
                'tables' => $tables,
                'how' => 'pg_database_size, pg_total_relation_size',
                'estimated' => true,
                'notes' => ['Row counts are PostgreSQL\'s estimates from the last ANALYZE or VACUUM. Data includes TOAST; partitioned tables count their partitions apart.'],
            ]);
        }
        $pageSize = (int) $pdo->query('PRAGMA page_size')->fetchColumn();
        $pages = (int) $pdo->query('PRAGMA page_count')->fetchColumn();
        $free = (int) $pdo->query('PRAGMA freelist_count')->fetchColumn();
        $count = (int) $pdo->query("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'")->fetchColumn();
        $views = (int) $pdo->query("SELECT COUNT(*) FROM sqlite_master WHERE type = 'view'")->fetchColumn();
        $result = [
            'databaseBytes' => $pageSize * $pages,
            'freeBytes' => $free > 0 ? $pageSize * $free : null,
            'tableCount' => $count,
            'viewCount' => $views > 0 ? $views : null,
            'tables' => [],
        ];
        try {
            $owners = [];
            foreach ($pdo->query("SELECT name, type, tbl_name FROM sqlite_master WHERE type IN ('table', 'index')")->fetchAll(\PDO::FETCH_NUM) as $object) {
                $owners[(string) $object[0]] = [(string) $object[1], (string) $object[2]];
            }
            $sizes = [];
            foreach ($pdo->query('SELECT name, SUM(pgsize) FROM dbstat GROUP BY name')->fetchAll(\PDO::FETCH_NUM) as $row) {
                $owner = $owners[(string) $row[0]] ?? null;
                if ($owner === null || strpos($owner[1], 'sqlite_') === 0) {
                    continue; // The schema table itself, or SQLite's own tables.
                }
                $table = $owner[1];
                $sizes[$table] = $sizes[$table] ?? ['name' => $table, 'dataBytes' => 0, 'indexBytes' => 0];
                $sizes[$table][$owner[0] === 'index' ? 'indexBytes' : 'dataBytes'] += (int) $row[1];
            }
            foreach ($sizes as $name => $size) {
                $sizes[$name]['totalBytes'] = $size['dataBytes'] + $size['indexBytes'];
            }
            usort($sizes, static function (array $a, array $b): int {
                return [$b['totalBytes'], $a['name']] <=> [$a['totalBytes'], $b['name']];
            });
            $result['tables'] = array_slice($sizes, 0, self::MAX_TABLES);
            $result['how'] = 'dbstat';
        } catch (\Throwable $error) {
            $result['how'] = 'page_count';
            $result['notes'] = ['Per-table sizes need SQLite\'s dbstat table, which this PHP\'s SQLite leaves out; the size is the whole file\'s.'];
        }

        return self::filtered($result);
    }

    /**
     * The server's sessions this user may see, and what it may not see or end.
     *
     * @return array<string, mixed>
     */
    private static function sessions(\PDO $pdo, string $dialect, int $own): array
    {
        if ($dialect === 'sqlite') {
            return ['list' => [], 'visibility' => 'none', 'notes' => ['SQLite has no server and no sessions: the database is a file the runner\'s PHP opens itself.']];
        }
        $budget = self::MAX_QUERIES_BYTES;
        $list = [];
        $notes = [];
        if ($dialect === 'mysql') {
            $current = self::currentUserName($pdo);
            $privileges = self::privileges($pdo);
            $statement = $pdo->query("SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, INFO FROM information_schema.PROCESSLIST ORDER BY COMMAND = 'Sleep', TIME DESC, ID LIMIT " . (self::MAX_SESSIONS + 1));
            $others = false;
            while (($row = $statement->fetch(\PDO::FETCH_NUM)) !== false) {
                $command = (string) $row[4];
                $others = $others || ($current !== null && (string) $row[1] !== $current);
                $list[] = self::filtered([
                    'id' => (int) $row[0],
                    'user' => $row[1] === null ? null : (string) $row[1],
                    'host' => $row[2] === null || (string) $row[2] === '' ? null : (string) $row[2],
                    'database' => $row[3] === null ? null : (string) $row[3],
                    'command' => $command,
                    'state' => $row[6] === null || (string) $row[6] === '' ? null : (string) $row[6],
                    'active' => !in_array($command, ['Sleep', 'Daemon', 'Binlog Dump', 'Killed'], true) ? true : null,
                    'seconds' => $row[5] === null ? null : (float) $row[5],
                    'own' => (int) $row[0] === $own ? true : null,
                ] + self::query($row[7], $budget));
            }
            $statement->closeCursor();
            self::lockWaits($pdo, $list);
            $process = $privileges === null ? null : in_array('PROCESS', $privileges, true);
            $all = $process === true || $others;
            $endOthers = $privileges === null ? null : count(array_intersect(['SUPER', 'CONNECTION ADMIN', 'CONNECTION_ADMIN'], $privileges)) > 0;
            if (!$all) {
                $connected = self::status($pdo, ['Threads_connected'], 'GLOBAL');
                $notes[] = 'You see only your own sessions: seeing every session needs the PROCESS privilege' . (isset($connected['Threads_connected']) ? ' (' . (int) $connected['Threads_connected'] . ' connected in all).' : '.');
            }
            if ($endOthers === false) {
                $notes[] = 'You can cancel and kill only your own sessions: other users\' need ' . (stripos((string) $pdo->getAttribute(\PDO::ATTR_SERVER_VERSION), 'mariadb') !== false ? 'CONNECTION ADMIN' : 'CONNECTION_ADMIN') . ' or SUPER.';
            }
            $visibility = $all ? 'all' : 'own';
        } else {
            $roles = $pdo->query("SELECT r.rolsuper, pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER'), pg_has_role(current_user, 'pg_signal_backend', 'MEMBER') FROM pg_roles r WHERE r.rolname = current_user")->fetch(\PDO::FETCH_NUM);
            $super = is_array($roles) && self::truthy($roles[0]);
            $readAll = $super || (is_array($roles) && self::truthy($roles[1]));
            $signal = $super || (is_array($roles) && self::truthy($roles[2]));
            $statement = $pdo->query("SELECT pid, usename, host(client_addr), client_port, client_hostname, datname, application_name, state, EXTRACT(EPOCH FROM (now() - COALESCE(state_change, backend_start)))::float8, EXTRACT(EPOCH FROM (now() - xact_start))::float8, backend_start::text, query_start::text, wait_event_type, wait_event, pg_blocking_pids(pid), query FROM pg_stat_activity WHERE " . self::PG_CLIENTS . " ORDER BY state IS DISTINCT FROM 'active', state_change, pid LIMIT " . (self::MAX_SESSIONS + 1));
            $hidden = 0;
            while (($row = $statement->fetch(\PDO::FETCH_NUM)) !== false) {
                $state = $row[7] === null ? null : (string) $row[7];
                $query = $row[15];
                if ($query === '<insufficient privilege>') {
                    $query = null;
                    ++$hidden;
                }
                $host = $row[2] === null ? ($row[3] !== null && (int) $row[3] === -1 ? 'local socket' : null) : (string) $row[2] . ($row[3] === null ? '' : ':' . $row[3]);
                $list[] = self::filtered([
                    'id' => (int) $row[0],
                    'user' => $row[1] === null ? null : (string) $row[1],
                    'host' => $host,
                    'database' => $row[5] === null ? null : (string) $row[5],
                    'application' => $row[6] === null || (string) $row[6] === '' ? null : (string) $row[6],
                    'state' => $state,
                    'active' => $state === 'active' ? true : null,
                    'seconds' => $row[8] === null ? null : max(0.0, round((float) $row[8], 1)),
                    'transactionSeconds' => $row[9] === null ? null : max(0.0, round((float) $row[9], 1)),
                    'started' => $row[10] === null ? null : (string) $row[10],
                    'queryStarted' => $row[11] === null ? null : (string) $row[11],
                    'waiting' => $row[12] === null ? null : (string) $row[12] . ($row[13] === null ? '' : ': ' . $row[13]),
                    'blockedBy' => self::pids($row[14]),
                    'own' => (int) $row[0] === $own ? true : null,
                ] + self::query($query, $budget));
            }
            $statement->closeCursor();
            $background = (int) $pdo->query('SELECT COUNT(*) FROM pg_stat_activity WHERE NOT COALESCE(' . self::PG_CLIENTS . ', false)')->fetchColumn();
            if (!$readAll) {
                $notes[] = 'Other roles\' sessions show without their state and statement' . ($hidden > 0 ? ' (' . $hidden . ' here)' : '') . ': seeing them needs the pg_read_all_stats role.';
            }
            if (!$signal) {
                $notes[] = 'You can cancel and kill only your own role\'s sessions: other roles\' need the pg_signal_backend role (a superuser\'s need a superuser).';
            }
            if ($background > 0) {
                $notes[] = 'Not listed: ' . $background . ' background process' . ($background === 1 ? '' : 'es') . ' of the server (autovacuum, WAL writer, …).';
            }
            $visibility = $readAll ? 'all' : 'partial';
            $endOthers = $signal;
        }
        $truncated = count($list) > self::MAX_SESSIONS;
        if ($truncated) {
            $list = array_slice($list, 0, self::MAX_SESSIONS);
            $notes[] = 'Only the first ' . self::MAX_SESSIONS . ' sessions are listed (active ones first).';
        }

        return self::filtered([
            'list' => $list,
            'visibility' => $visibility,
            'endOthers' => $endOthers,
            'truncated' => $truncated ? true : null,
            'notes' => $notes === [] ? null : $notes,
        ]);
    }

    /**
     * MySQL and MariaDB: which sessions wait for a lock another session holds (InnoDB), as
     * `blockedBy` and `transactionSeconds`. Quietly nothing when the views aren't there or
     * readable (they need PROCESS; MySQL 8 moved lock waits to performance_schema).
     *
     * @param array<int, array<string, mixed>> $list
     */
    private static function lockWaits(\PDO $pdo, array &$list): void
    {
        if ($list === []) {
            return;
        }
        $index = [];
        foreach ($list as $position => $session) {
            $index[$session['id']] = $position;
        }
        try {
            foreach ($pdo->query('SELECT trx_mysql_thread_id, TIMESTAMPDIFF(SECOND, trx_started, NOW()) FROM information_schema.INNODB_TRX')->fetchAll(\PDO::FETCH_NUM) as $row) {
                if (isset($index[(int) $row[0]]) && $row[1] !== null) {
                    $list[$index[(int) $row[0]]]['transactionSeconds'] = (float) $row[1];
                }
            }
        } catch (\Throwable $error) {
            return;
        }
        $waits = [];
        foreach ([
            'SELECT r.trx_mysql_thread_id, b.trx_mysql_thread_id FROM information_schema.INNODB_LOCK_WAITS w JOIN information_schema.INNODB_TRX r ON r.trx_id = w.requesting_trx_id JOIN information_schema.INNODB_TRX b ON b.trx_id = w.blocking_trx_id',
            'SELECT r.trx_mysql_thread_id, b.trx_mysql_thread_id FROM performance_schema.data_lock_waits w JOIN information_schema.INNODB_TRX r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID JOIN information_schema.INNODB_TRX b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID',
        ] as $sql) {
            try {
                $waits = $pdo->query($sql)->fetchAll(\PDO::FETCH_NUM);
                break;
            } catch (\Throwable $error) {
                continue;
            }
        }
        foreach ($waits as $wait) {
            $position = $index[(int) $wait[0]] ?? null;
            if ($position !== null && !in_array((int) $wait[1], $list[$position]['blockedBy'] ?? [], true)) {
                $list[$position]['blockedBy'][] = (int) $wait[1];
            }
        }
    }

    /**
     * A session's statement, cut to MAX_QUERY_BYTES at a character boundary and within what is
     * left of the event's budget.
     *
     * @param mixed $query
     * @return array<string, mixed>
     */
    private static function query($query, int &$budget): array
    {
        if ($query === null) {
            return [];
        }
        $text = trim((string) $query);
        if ($text === '') {
            return [];
        }
        $limit = min(self::MAX_QUERY_BYTES, max(0, $budget));
        if (strlen($text) <= $limit) {
            $budget -= strlen($text);

            return ['query' => $text];
        }
        $cut = self::cut($text, $limit);
        $budget -= strlen($cut);

        return ['query' => $cut, 'queryBytes' => strlen($text)];
    }

    /** `$text` cut to at most `$bytes` bytes at a UTF-8 character boundary. */
    private static function cut(string $text, int $bytes): string
    {
        $cut = substr($text, 0, $bytes);
        while ($cut !== '' && preg_match('//u', $cut) !== 1) {
            $cut = substr($cut, 0, -1);
        }

        return $cut;
    }

    private static function bounded(string $text, int $bytes): string
    {
        return strlen($text) <= $bytes ? $text : self::cut($text, $bytes) . '…';
    }

    /**
     * What one session is now: its user, whether it runs a statement, its state, PostgreSQL's
     * backend start, and what tells its statement apart. Null when it isn't listed (gone, or
     * not visible to this user).
     *
     * @return array{user: string|null, running: bool|null, state: string|null, started: string|null, since: string|null, text: string|null}|null
     */
    private static function session(\PDO $pdo, string $dialect, int $session): ?array
    {
        try {
            if ($dialect === 'mysql') {
                $statement = $pdo->prepare('SELECT USER, COMMAND, TIME, STATE, INFO FROM information_schema.PROCESSLIST WHERE ID = ?');
                $statement->execute([$session]);
                $row = $statement->fetch(\PDO::FETCH_NUM);
                $statement->closeCursor();
                if (!is_array($row)) {
                    return null;
                }
                $command = (string) $row[1];

                return [
                    'user' => $row[0] === null ? null : (string) $row[0],
                    'running' => $command === 'Killed' ? false : $command !== 'Sleep',
                    'state' => trim($command . ($row[3] !== null && (string) $row[3] !== '' ? ', ' . $row[3] : '')),
                    'started' => null,
                    'since' => (string) $row[2],
                    'text' => $row[4] === null ? null : (string) $row[4],
                ];
            }
            $statement = $pdo->prepare('SELECT usename, state, backend_start::text, query_start::text FROM pg_stat_activity WHERE pid = ?');
            $statement->execute([$session]);
            $row = $statement->fetch(\PDO::FETCH_NUM);
            $statement->closeCursor();
            if (!is_array($row)) {
                return null;
            }
            $state = $row[1] === null ? null : (string) $row[1];

            return [
                'user' => $row[0] === null ? null : (string) $row[0],
                // Null for another role's session without pg_read_all_stats: its state isn't shown.
                'running' => $state === null ? null : $state === 'active',
                'state' => $state,
                'started' => $row[2] === null ? null : (string) $row[2],
                'since' => $row[3] === null ? null : (string) $row[3],
                'text' => null,
            ];
        } catch (\Throwable $error) {
            return null;
        }
    }

    /**
     * Whether `$now` still runs the statement `$before` saw.
     *
     * @param array<string, mixed> $before
     * @param array<string, mixed> $now
     */
    private static function sameStatement(array $before, array $now): bool
    {
        if ($before['text'] !== null || $now['text'] !== null) {
            return $before['text'] === $now['text'] && (int) $now['since'] >= (int) $before['since'];
        }

        return $before['since'] === $now['since'];
    }

    /**
     * Why the database refused the statement, as an outcome.
     *
     * @param callable(string, array<string, mixed>=): array<string, mixed> $done
     * @return array<string, mixed>
     */
    private static function refusal(callable $done, string $action, string $dialect, int $session, \PDOException $error): array
    {
        $code = is_array($error->errorInfo) ? ($error->errorInfo[1] ?? null) : null;
        $state = is_array($error->errorInfo) ? (string) ($error->errorInfo[0] ?? '') : (string) $error->getCode();
        $message = self::message($error);
        $verb = $action === 'kill' ? 'kill' : 'cancel the statement of';
        if ($dialect === 'mysql') {
            if ((int) $code === 1094) {
                return $done('alreadyEnded'); // Unknown thread id.
            }
            if ((int) $code === 1095) {
                return $done('refused', ['detail' => 'the database user may not ' . $verb . ' session ' . $session . ' (' . $message . '); other users\' sessions need the CONNECTION ADMIN (MariaDB), CONNECTION_ADMIN (MySQL), or SUPER privilege']);
            }
        } elseif ($state === '42501') {
            return $done('refused', ['detail' => 'the database user may not ' . $verb . ' session ' . $session . ' (' . $message . '); other roles\' sessions need membership in pg_signal_backend, and a superuser\'s need a superuser']);
        }

        return $done('failed', ['detail' => $message]);
    }

    /** The database's own words, without PDO's SQLSTATE prefix. */
    private static function message(\Throwable $error): string
    {
        if ($error instanceof \PDOException) {
            $info = $error->errorInfo;
            if (is_array($info) && isset($info[2]) && is_string($info[2]) && $info[2] !== '') {
                return trim(preg_replace('/^ERROR:\s+/', '', $info[2]) ?? $info[2]);
            }
        }

        return $error->getMessage();
    }

    /**
     * MySQL status variables by name (`SHOW GLOBAL|SESSION STATUS` needs no privilege).
     *
     * @param string[] $names
     * @return array<string, string>
     */
    private static function status(\PDO $pdo, array $names, string $scope): array
    {
        try {
            $quoted = implode(', ', array_map(static function (string $name): string {
                return "'" . $name . "'";
            }, $names));

            return array_map('strval', $pdo->query('SHOW ' . $scope . ' STATUS WHERE Variable_name IN (' . $quoted . ')')->fetchAll(\PDO::FETCH_KEY_PAIR));
        } catch (\Throwable $error) {
            return [];
        }
    }

    /**
     * MySQL: the current account's global privileges (information_schema.USER_PRIVILEGES lists
     * the user's own); null when Runlet can't tell. Roles' privileges may be missing.
     *
     * @return string[]|null
     */
    private static function privileges(\PDO $pdo): ?array
    {
        try {
            $account = (string) $pdo->query('SELECT CURRENT_USER()')->fetchColumn();
            $at = strrpos($account, '@');
            if ($at === false) {
                return null;
            }
            $grantee = "'" . substr($account, 0, $at) . "'@'" . substr($account, $at + 1) . "'";
            $statement = $pdo->prepare('SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE = ?');
            $statement->execute([$grantee]);

            return array_map('strval', $statement->fetchAll(\PDO::FETCH_COLUMN));
        } catch (\Throwable $error) {
            return null;
        }
    }

    /** MySQL: the user name the server lists this user's threads under. */
    private static function currentUserName(\PDO $pdo): ?string
    {
        try {
            $user = $pdo->query("SELECT SUBSTRING_INDEX(USER(), '@', 1)")->fetchColumn();

            return $user === false || $user === null ? null : (string) $user;
        } catch (\Throwable $error) {
            return null;
        }
    }

    /**
     * PostgreSQL's int[] as text ("{12,34}") or an array, as ints; null when empty.
     *
     * @param mixed $value
     * @return int[]|null
     */
    private static function pids($value): ?array
    {
        if (is_array($value)) {
            $items = $value;
        } else {
            $text = trim((string) $value, '{} ');
            $items = $text === '' ? [] : explode(',', $text);
        }
        $pids = array_values(array_filter(array_map('intval', $items), static function (int $pid): bool {
            return $pid > 0;
        }));

        return $pids === [] ? null : $pids;
    }

    /** "11.4.2" from "11.4.2-MariaDB-ubu2404", "5.5.5-10.6.12-MariaDB", or "14.23 (Debian …)". */
    private static function number(string $version): string
    {
        $version = preg_replace('/^5\.5\.5-/', '', $version) ?? $version;

        return preg_match('/^\d+(\.\d+)*/', $version, $match) === 1 ? $match[0] : self::bounded($version, 60);
    }

    /** @param mixed $value */
    private static function truthy($value): bool
    {
        return in_array($value, [true, 1, '1', 't', 'true', 'on'], true);
    }

    /**
     * @param array<string, mixed> $fields
     * @return array<string, mixed>
     */
    private static function filtered(array $fields): array
    {
        return array_filter($fields, static function ($value): bool {
            return $value !== null;
        });
    }
}
