<?php

declare(strict_types=1);

/*
 * WordPress's own PDO connection for SQL tabs (#208). WordPressDriver::sqlConnection() asks
 * for it when an SQL feature needs the connection, never while WordPress boots. It is opened
 * with the application's own settings, read in the target's PHP after WordPress loaded, as
 * Laravel's connection uses its .env: Runlet never asks for, sees, or stores them.
 *
 *  - MySQL and MariaDB (`$wpdb` is WordPress's own wpdb, or Query Monitor's QM_DB, which only
 *    times queries): pdo_mysql with DB_HOST (every form wpdb::parse_db_host() reads: host,
 *    host:port, host:/socket, :/socket, [IPv6]:port), DB_NAME, DB_USER, DB_PASSWORD, and the
 *    charset and collation $wpdb uses. MYSQL_CLIENT_FLAGS with MYSQLI_CLIENT_SSL, and the
 *    MYSQL_SSL_CA / _CAPATH / _CERT / _KEY / _CIPHER constants hosts set, turn on TLS (checked
 *    after connecting). The session's sql_mode loses the modes wpdb removes.
 *  - The SQLite Database Integration drop-in: pdo_sqlite on its file (FQDB, else DB_DIR and
 *    DB_FILE), with foreign keys on, as the drop-in opens it. Statements are SQLite's there.
 *
 * Otherwise SQL tabs keep running statements through $wpdb (SqlConnections::wpdb()), and the
 * origin says why: RUNLET_WPDB_ONLY is set, a db.php drop-in Runlet doesn't recognise (HyperDB,
 * LudicrousDB, a custom one, a multisite's separate databases), $wpdb connected with other
 * settings than the constants, a missing PDO driver, or a connection that failed.
 *
 * The password is read from DB_PASSWORD inside connect(), which takes no arguments, with
 * zend.exception_ignore_args on; PDO's errors are rethrown as their message only, scrubbed,
 * and Channel replaces the password in every error, notice, and log event from then on.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

/** The WordPress PDO connection can't be opened; the message is the reason (scrubbed). */
final class WordPressPdoUnavailable extends \RuntimeException
{
}

final class WordPressDatabase
{
    /** Where results say a PDO connection came from. */
    public const PDO_ORIGIN = 'WordPress (PDO from wp-config)';
    /** Where results say a statement ran when the tab chose the `wpdb` connection. */
    public const WPDB_ORIGIN = 'WordPress $wpdb';
    /** $wpdb classes that connect with wpdb's own db_connect(), from wp-config's constants. */
    private const MYSQL_CLASSES = ['wpdb', 'QM_DB'];
    /** wpdb::$incompatible_modes: the SQL modes wpdb removes from its session. */
    private const INCOMPATIBLE_MODES = ['NO_ZERO_DATE', 'ONLY_FULL_GROUP_BY', 'STRICT_TRANS_TABLES', 'STRICT_ALL_TABLES', 'TRADITIONAL', 'ANSI'];
    /** mysqli's client flags (MYSQLI_CLIENT_*), for PHP without mysqli. */
    private const CLIENT_COMPRESS = 32;
    private const CLIENT_SSL_DONT_VERIFY = 64;
    private const CLIENT_SSL = 2048;
    private const CLIENT_SSL_VERIFY = 1073741824;
    /** The TLS constants hosts define, by the PDO attribute they become. */
    private const TLS_CONSTANTS = ['SSL_CA' => 'MYSQL_SSL_CA', 'SSL_CAPATH' => 'MYSQL_SSL_CAPATH', 'SSL_CERT' => 'MYSQL_SSL_CERT', 'SSL_KEY' => 'MYSQL_SSL_KEY', 'SSL_CIPHER' => 'MYSQL_SSL_CIPHER'];
    /** Well-known db.php drop-ins Runlet leaves to $wpdb, by their class. */
    private const KNOWN_DROPINS = ['hyperdb' => 'HyperDB', 'ludicrousdb' => 'LudicrousDB', 'm_wpdb' => 'Multi-DB', 'shardb' => 'SharDB'];
    /** Characters kept of PDO's message in the origin. */
    private const MAX_REASON_BYTES = 200;

    /** @var array{pdo: \PDO|null, origin: string}|null This process's connection, opened once. */
    private static $opened;
    /** @var string|null Where the last connection() came from. */
    private static $lastOrigin;
    /** @var array<string, mixed>|null The plan connect() opens; never holds the password. */
    private static $plan;

    /**
     * SQL tabs' connection for WordPress: this process's PDO, opened on first use, or $wpdb's
     * callable when PDO isn't possible (origin() says why). `$wpdbOnly` (the tab chose the
     * `wpdb` connection) always returns the callable and opens nothing.
     *
     * @param object $wpdb
     * @return \PDO|callable
     */
    public static function connection($wpdb, bool $wpdbOnly = false)
    {
        if ($wpdbOnly) {
            self::$lastOrigin = self::WPDB_ORIGIN;

            return \Runlet\SqlConnections::wpdb($wpdb);
        }
        if (self::$opened === null) {
            self::$opened = self::open($wpdb);
        }
        self::$lastOrigin = self::$opened['origin'];

        return self::$opened['pdo'] ?? \Runlet\SqlConnections::wpdb($wpdb);
    }

    /** "WordPress (PDO from wp-config)" or "WordPress ($wpdb, because …)"; null before connection(). */
    public static function origin(): ?string
    {
        return self::$lastOrigin;
    }

    /** Whether `$origin` is a connection through $wpdb's callable (which speaks MySQL). */
    public static function isWpdb(string $origin): bool
    {
        return $origin === self::WPDB_ORIGIN || strpos($origin, 'WordPress ($wpdb') === 0;
    }

    /** @return array{pdo: \PDO|null, origin: string} */
    private static function open($wpdb): array
    {
        $plan = self::plan(self::environment($wpdb));
        if (isset($plan['fallback'])) {
            return self::fallback((string) $plan['fallback']);
        }
        if ($plan['driver'] === 'mysql' && defined('DB_PASSWORD')) {
            // Errors, notices, and log lines never carry it (results are the database's data).
            Channel::addSecret((string) constant('DB_PASSWORD'), false);
        }
        self::$plan = $plan;
        try {
            $pdo = self::connect();
            $details = self::configure($pdo, $plan);
        } catch (WordPressPdoUnavailable $unavailable) {
            return self::fallback($unavailable->getMessage());
        } catch (\Throwable $error) {
            return self::fallback(Channel::scrub('PDO couldn\'t set the session up as $wpdb does: ' . $error->getMessage()));
        } finally {
            self::$plan = null;
        }
        Runner::log('sql', 'WordPress: PDO connection from wp-config.php (' . $plan['summary'] . ')', $details === [] ? null : implode("\n", $details));

        return ['pdo' => $pdo, 'origin' => self::PDO_ORIGIN];
    }

    /** @return array{pdo: null, origin: string} */
    private static function fallback(string $reason): array
    {
        $reason = Channel::scrub($reason);
        if (strlen($reason) > self::MAX_REASON_BYTES) {
            $cut = function_exists('mb_strcut') ? mb_strcut($reason, 0, self::MAX_REASON_BYTES, 'UTF-8') : substr($reason, 0, self::MAX_REASON_BYTES);
            $reason = rtrim($cut) . '…';
        }
        Runner::log('sql', 'WordPress: statements run through $wpdb, because ' . $reason, 'Browse Table edits, bound values, Import CSV, Explain, the server panel, and cancelling on the server need a PDO connection.'
            . (strpos($reason, 'RUNLET_WPDB_ONLY') === 0 ? ' Remove RUNLET_WPDB_ONLY to let Runlet open one from wp-config.php.' : ' Define RUNLET_WPDB_ONLY in wp-config.php to use $wpdb without trying PDO, or save a connection for this target.'));

        return ['pdo' => null, 'origin' => 'WordPress ($wpdb, because ' . $reason . ')'];
    }

    /**
     * What plan() reads, from the running WordPress: `class` ($wpdb's), `dropIn` (the db.php
     * drop-in's path, or null), `multisite`, `wpdbOnly` (RUNLET_WPDB_ONLY), `engine`
     * (DB_ENGINE), `sqliteFile` (FQDB, else DB_DIR/WP_CONTENT_DIR and DB_FILE), the `name`,
     * `user`, and `host` constants (null when not text), `charset` and `collate` ($wpdb's, else
     * DB_CHARSET / DB_COLLATE), `flags` (MYSQL_CLIENT_FLAGS), `tls` (the MYSQL_SSL_* constants),
     * `wpdb` ($wpdb's own dbname, dbhost, and dbuser, when it has them), and `defaultSocket` /
     * `defaultPort` (mysqli's defaults). Never the password.
     *
     * @param object $wpdb
     * @return array<string, mixed>
     */
    public static function environment($wpdb): array
    {
        $text = static function (string $name): ?string {
            if (!defined($name)) {
                return null;
            }
            $value = constant($name);

            return is_string($value) || is_int($value) ? (string) $value : null;
        };
        $contentDir = defined('WP_CONTENT_DIR') ? rtrim((string) WP_CONTENT_DIR, '/') : (defined('ABSPATH') ? rtrim((string) ABSPATH, '/') . '/wp-content' : null);
        $dropIn = $contentDir !== null && is_file($contentDir . '/db.php') ? $contentDir . '/db.php' : null;
        $sqliteFile = $text('FQDB');
        if ($sqliteFile === null) {
            $directory = $text('DB_DIR');
            $directory = $directory !== null ? rtrim($directory, '/') . '/' : ($contentDir !== null ? $contentDir . '/database/' : null);
            $sqliteFile = $directory === null ? null : $directory . ($text('DB_FILE') ?? '.ht.sqlite');
        }
        $tls = [];
        foreach (self::TLS_CONSTANTS as $constant) {
            $value = $text($constant);
            if ($value !== null && $value !== '') {
                $tls[$constant] = $value;
            }
        }
        $own = [];
        foreach (['dbname' => 'name', 'dbhost' => 'host', 'dbuser' => 'user'] as $property => $key) {
            $value = self::property($wpdb, $property);
            if (is_string($value)) {
                $own[$key] = $value;
            }
        }
        $charset = self::property($wpdb, 'charset');
        $collate = self::property($wpdb, 'collate');
        $flags = defined('MYSQL_CLIENT_FLAGS') ? constant('MYSQL_CLIENT_FLAGS') : 0;

        return [
            'class' => get_class($wpdb),
            'dropIn' => $dropIn,
            'multisite' => function_exists('is_multisite') && \is_multisite(),
            'wpdbOnly' => defined('RUNLET_WPDB_ONLY') && (bool) constant('RUNLET_WPDB_ONLY'),
            'engine' => $text('DB_ENGINE'),
            'sqliteFile' => $sqliteFile,
            'name' => $text('DB_NAME'),
            'user' => $text('DB_USER'),
            'host' => $text('DB_HOST'),
            'charset' => is_string($charset) && $charset !== '' ? $charset : ($text('DB_CHARSET') ?? ''),
            'collate' => is_string($collate) && $collate !== '' ? $collate : ($text('DB_COLLATE') ?? ''),
            'flags' => is_int($flags) ? $flags : (int) $flags,
            'tls' => $tls,
            'wpdb' => $own,
            'defaultSocket' => (string) ini_get('mysqli.default_socket'),
            'defaultPort' => (int) ini_get('mysqli.default_port'),
        ];
    }

    /** A property of $wpdb, also a protected one (wpdb's dbname, dbhost, …), without running its code; null when it has none. */
    private static function property($object, string $name)
    {
        try {
            $reflection = new \ReflectionObject($object);
            if (!$reflection->hasProperty($name)) {
                return null;
            }
            $property = $reflection->getProperty($name);
            $property->setAccessible(true);

            return $property->isInitialized($object) ? $property->getValue($object) : null;
        } catch (\Throwable $error) {
            return null;
        }
    }

    /**
     * How the connection opens: `driver`, `dsn`, `user`, `attributes` (by constant name, as
     * SqlConnect::plan()), `tls`, `charset`, `collate`, and a `summary` for messages, or
     * `fallback` with the reason $wpdb is kept. `$environment` is environment()'s shape;
     * `$available` defaults to this PHP's PDO drivers. Opens nothing.
     *
     * @param array<string, mixed> $environment
     * @param string[]|null $available
     * @return array<string, mixed>
     */
    public static function plan(array $environment, ?array $available = null): array
    {
        if (!empty($environment['wpdbOnly'])) {
            return ['fallback' => 'RUNLET_WPDB_ONLY is set'];
        }
        if ($available === null) {
            $available = class_exists('PDO', false) ? \PDO::getAvailableDrivers() : [];
        }
        $class = (string) ($environment['class'] ?? '');
        $mysqlClass = in_array(strtolower($class), array_map('strtolower', self::MYSQL_CLASSES), true);
        if (stripos($class, 'sqlite') !== false || (!$mysqlClass && strtolower((string) ($environment['engine'] ?? '')) === 'sqlite')) {
            return self::sqlitePlan($environment, $available);
        }
        if (!$mysqlClass) {
            $known = self::KNOWN_DROPINS[strtolower($class)] ?? $class;
            $by = ($environment['dropIn'] ?? null) !== null ? 'the db.php drop-in replaces wpdb with ' . $known : '$wpdb is ' . $known . ', not wpdb';

            return ['fallback' => $by . ', which Runlet doesn\'t open itself' . (!empty($environment['multisite']) ? ' (a multisite\'s databases can be split)' : '')];
        }
        $name = $environment['name'] ?? null;
        $user = $environment['user'] ?? null;
        $host = $environment['host'] ?? null;
        if (!is_string($name) || $name === '' || !is_string($user) || !is_string($host)) {
            return ['fallback' => 'wp-config.php doesn\'t define DB_NAME, DB_USER, and DB_HOST as text'];
        }
        $own = is_array($environment['wpdb'] ?? null) ? $environment['wpdb'] : [];
        foreach (['name' => 'DB_NAME', 'host' => 'DB_HOST', 'user' => 'DB_USER'] as $key => $constant) {
            if (isset($own[$key]) && $own[$key] !== $environment[$key]) {
                return ['fallback' => '$wpdb connected with another ' . $constant . ' than wp-config.php defines'];
            }
        }
        if (!in_array('mysql', $available, true)) {
            return ['fallback' => 'this PHP has no pdo_mysql (it has ' . ($available === [] ? 'no PDO drivers' : 'pdo_' . implode(', pdo_', $available)) . ')'];
        }
        $parsed = self::parseHost($host);
        if ($parsed === null) {
            return ['fallback' => 'DB_HOST "' . $host . '" isn\'t a host, port, or socket Runlet can read'];
        }
        [$address, $port, $socket, $ipv6] = $parsed;
        if ($address !== '' && preg_match('/^[A-Za-z0-9._%:-]+$/', $address) !== 1) {
            return ['fallback' => 'DB_HOST "' . $host . '" isn\'t a host, port, or socket Runlet can read'];
        }
        if (preg_match('/[;\x00-\x1f]/', $name) === 1) {
            return ['fallback' => 'DB_NAME contains ";" or control characters, which a PDO DSN can\'t hold'];
        }
        // mysqli (and so $wpdb) talks to "localhost" over a Unix socket: DB_HOST's, else mysqli's default.
        $local = $address === '' || strtolower($address) === 'localhost';
        if ($local) {
            $socket = $socket ?? (($environment['defaultSocket'] ?? '') !== '' ? (string) $environment['defaultSocket'] : null);
            if ($socket !== null && preg_match('/[;\x00-\x1f]/', $socket) === 1) {
                return ['fallback' => 'the socket path in DB_HOST contains ";" or control characters'];
            }
            $dsn = 'mysql:host=localhost' . ($socket !== null ? ';unix_socket=' . $socket : '');
            $where = 'localhost' . ($socket !== null ? ' (' . $socket . ')' : '');
        } else {
            $port = $port ?? ((int) ($environment['defaultPort'] ?? 0) > 0 ? (int) $environment['defaultPort'] : 3306);
            $address = $ipv6 ? '[' . $address . ']' : $address;
            $dsn = 'mysql:host=' . $address . ';port=' . $port;
            $where = $address . ':' . $port;
        }
        $dsn .= ';dbname=' . $name;
        $charset = (string) ($environment['charset'] ?? '');
        $collate = (string) ($environment['collate'] ?? '');
        if ($charset !== '') {
            if (preg_match('/^[A-Za-z0-9_]{1,40}$/', $charset) !== 1) {
                return ['fallback' => 'the charset "' . $charset . '" isn\'t a character set name'];
            }
            $dsn .= ';charset=' . $charset;
        }
        if ($collate !== '' && preg_match('/^[A-Za-z0-9_]{1,64}$/', $collate) !== 1) {
            return ['fallback' => 'the collation "' . $collate . '" isn\'t a collation name'];
        }
        $attributes = ['PDO::ATTR_TIMEOUT' => [\PDO::ATTR_TIMEOUT, 10]];
        $flags = (int) ($environment['flags'] ?? 0);
        $tlsConstants = is_array($environment['tls'] ?? null) ? $environment['tls'] : [];
        $tls = ($flags & self::CLIENT_SSL) !== 0 || $tlsConstants !== [];
        if ($tls) {
            $verify = ($flags & self::CLIENT_SSL_VERIFY) !== 0
                ? true
                // mysqlnd checks the server's certificate when it has a CA to check it with.
                : (($flags & self::CLIENT_SSL_DONT_VERIFY) !== 0 ? false : isset($tlsConstants['MYSQL_SSL_CA']) || isset($tlsConstants['MYSQL_SSL_CAPATH']));
            $set = ['SSL_CA' => ''];
            foreach (self::TLS_CONSTANTS as $suffix => $constant) {
                if (isset($tlsConstants[$constant])) {
                    $value = (string) $tlsConstants[$constant];
                    if ($suffix !== 'SSL_CIPHER' && ($value[0] !== '/' || !is_readable($value))) {
                        return ['fallback' => $constant . ' (' . $value . ') isn\'t a file this PHP can read'];
                    }
                    $set[$suffix] = $value;
                }
            }
            if (isset($set['SSL_CAPATH']) && !isset($tlsConstants['MYSQL_SSL_CA'])) {
                unset($set['SSL_CA']);
            }
            $set['SSL_VERIFY_SERVER_CERT'] = $verify;
            foreach ($set as $suffix => $value) {
                $constant = SqlConnect::constant(['Pdo\Mysql::ATTR_' . $suffix, 'PDO::MYSQL_ATTR_' . $suffix]);
                if ($constant === null) {
                    return ['fallback' => 'wp-config.php asks for TLS, and this PHP\'s pdo_mysql has no PDO::MYSQL_ATTR_' . $suffix];
                }
                $attributes[$constant[0]] = [$constant[1], $value];
            }
        }
        if (($flags & self::CLIENT_COMPRESS) !== 0) {
            $compress = SqlConnect::constant(['Pdo\Mysql::ATTR_COMPRESS', 'PDO::MYSQL_ATTR_COMPRESS']);
            if ($compress !== null) {
                $attributes[$compress[0]] = [$compress[1], true];
            }
        }

        return [
            'driver' => 'mysql',
            'dsn' => $dsn,
            'user' => $user,
            'attributes' => $attributes,
            'tls' => $tls,
            'charset' => $charset,
            'collate' => $collate,
            'summary' => 'mysql, ' . $where . '/' . $name . ($tls ? ', TLS' : ''),
        ];
    }

    /**
     * @param array<string, mixed> $environment
     * @param string[] $available
     * @return array<string, mixed>
     */
    private static function sqlitePlan(array $environment, array $available): array
    {
        if (!in_array('sqlite', $available, true)) {
            return ['fallback' => 'the SQLite drop-in needs pdo_sqlite, and this PHP has ' . ($available === [] ? 'no PDO drivers' : 'pdo_' . implode(', pdo_', $available))];
        }
        $file = $environment['sqliteFile'] ?? null;
        if (!is_string($file) || $file === '' || !is_file($file)) {
            return ['fallback' => 'the SQLite drop-in\'s database file' . (is_string($file) && $file !== '' ? ' (' . $file . ')' : '') . ' wasn\'t found (FQDB, or DB_DIR and DB_FILE)'];
        }

        return [
            'driver' => 'sqlite',
            'dsn' => 'sqlite:' . $file,
            'user' => null,
            'attributes' => ['PDO::ATTR_TIMEOUT' => [\PDO::ATTR_TIMEOUT, 10]],
            'tls' => false,
            'charset' => '',
            'collate' => '',
            'summary' => 'sqlite, ' . $file,
        ];
    }

    /**
     * wpdb::parse_db_host(): DB_HOST as [host, port, socket, isIPv6]. "host", "host:port",
     * "host:/path/to.sock", ":/path/to.sock", "[::1]", "[::1]:3306" (and a bare IPv6 address).
     * Null when wpdb couldn't read it either.
     *
     * @return array{0: string, 1: int|null, 2: string|null, 3: bool}|null
     */
    public static function parseHost(string $host): ?array
    {
        $socket = null;
        $position = strpos($host, ':/');
        if ($position !== false) {
            $socket = substr($host, $position + 1);
            $host = substr($host, 0, $position);
        }
        $ipv6 = substr_count($host, ':') > 1;
        $pattern = $ipv6 ? '#^(?:\[)?(?P<host>[0-9a-fA-F:]+)(?:\]:(?P<port>[\d]+))?#' : '#^(?P<host>[^:/]*)(?::(?P<port>[\d]+))?#';
        if (preg_match($pattern, $host, $matches) !== 1) {
            return null;
        }
        $port = !empty($matches['port']) ? abs((int) $matches['port']) : null;

        return [!empty($matches['host']) ? $matches['host'] : '', $port === 0 ? null : $port, $socket, $ipv6];
    }

    /**
     * Opens self::$plan. It takes no arguments, so neither the password nor the DSN is in a
     * stack frame; PDO's exception is replaced by one with its (scrubbed) message only.
     */
    private static function connect(): \PDO
    {
        $plan = self::$plan;
        if ($plan === null) {
            throw new WordPressPdoUnavailable('no connection was planned');
        }
        $options = [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION];
        foreach ($plan['attributes'] as [$key, $value]) {
            $options[$key] = $value;
        }
        $ignoreArgs = ini_get('zend.exception_ignore_args');
        ini_set('zend.exception_ignore_args', '1');
        $warnings = [];
        set_error_handler(static function (int $severity, string $message) use (&$warnings): bool {
            $warnings[] = $message;

            return true;
        });
        $message = '';
        $pdo = null;
        try {
            $pdo = $plan['driver'] === 'sqlite'
                ? new \PDO($plan['dsn'], null, null, $options)
                : new \PDO($plan['dsn'], $plan['user'], defined('DB_PASSWORD') ? (string) constant('DB_PASSWORD') : '', $options);
        } catch (\Throwable $error) {
            $message = $error->getMessage();
        } finally {
            restore_error_handler();
            if ($ignoreArgs !== false) {
                ini_set('zend.exception_ignore_args', $ignoreArgs);
            }
        }
        if ($pdo === null) {
            if ($message === '' && $warnings !== []) {
                $message = implode(' ', $warnings);
            }
            // Thrown outside the catch, with no previous exception: nothing of PDO's trace stays.
            throw new WordPressPdoUnavailable(Channel::scrub('PDO couldn\'t connect: ' . $message));
        }

        return $pdo;
    }

    /**
     * The session as $wpdb has it: MySQL's TLS checked, SET NAMES with the collation, and the
     * sql_mode without wpdb's incompatible modes; SQLite's foreign keys on. Returns what it set,
     * for the Run Log.
     *
     * @param array<string, mixed> $plan
     * @return string[]
     */
    private static function configure(\PDO $pdo, array $plan): array
    {
        if ($plan['driver'] === 'sqlite') {
            $pdo->exec('PRAGMA foreign_keys = ON');

            return ['foreign keys on, as the SQLite drop-in opens the file'];
        }
        $details = [];
        if ($plan['tls']) {
            $row = $pdo->query("SHOW SESSION STATUS LIKE 'Ssl_cipher'")->fetch(\PDO::FETCH_NUM);
            $cipher = is_array($row) ? (string) ($row[1] ?? '') : '';
            if ($cipher === '') {
                throw new WordPressPdoUnavailable('wp-config.php asks for TLS, and the server didn\'t encrypt the PDO session');
            }
            $details[] = 'TLS: ' . $cipher;
        }
        if ($plan['charset'] !== '' && $plan['collate'] !== '') {
            $pdo->exec("SET NAMES '" . $plan['charset'] . "' COLLATE '" . $plan['collate'] . "'");
        }
        if ($plan['charset'] !== '') {
            $details[] = 'charset ' . $plan['charset'] . ($plan['collate'] !== '' ? ', collation ' . $plan['collate'] : '');
        }
        $current = $pdo->query('SELECT @@SESSION.sql_mode')->fetchColumn();
        if (is_string($current) && $current !== '') {
            $incompatible = self::INCOMPATIBLE_MODES;
            if (function_exists('apply_filters')) {
                $incompatible = (array) \apply_filters('incompatible_sql_modes', $incompatible);
            }
            $modes = array_values(array_filter(explode(',', $current), static function (string $mode) use ($incompatible): bool {
                return !in_array(strtoupper($mode), $incompatible, true);
            }));
            $statement = $pdo->prepare('SET SESSION sql_mode = ?');
            $statement->execute([implode(',', $modes)]);
            $details[] = 'sql_mode ' . ($modes === [] ? '(empty)' : implode(',', $modes)) . ', without the modes wpdb removes';
        }

        return $details;
    }
}
