<?php

declare(strict_types=1);

/*
 * Saved database connections (#138): a connection the user saved for a target, opened in
 * the target's own PHP (local PHP, `docker exec`, SSH), or from this Mac (#142: Runlet's PHP
 * or the default PHP, in an empty folder of Runlet's; `place` is "mac"), which is also where
 * connections of all targets open. The app sends its definition and
 * password in the runner request, which reaches PHP only on stdin; Runner::main() hands the
 * definition to SqlConnect::configure() and drops it from the request before anything else
 * runs, and the run boots no project code (the `plain` bootstrap).
 *
 * The password:
 *  - is never a function argument: connect() reads it from a private property, and the
 *    run sets zend.exception_ignore_args, so no exception trace carries it;
 *  - is forgotten once the connection is open (Channel keeps what it needs to scrub);
 *  - never leaves in an event: Channel::emit() replaces it (and its URL-encoded forms)
 *    with ••• in every message, and PDO's errors are rethrown with their message only.
 *
 * Read-only connections (#139): connect() makes the session read-only before anything else
 * runs (MySQL/MariaDB: SET SESSION TRANSACTION READ ONLY; PostgreSQL: SET SESSION
 * CHARACTERISTICS AS TRANSACTION READ ONLY; SQLite: the file opened read-only, and PRAGMA
 * query_only), checks that the database took it, and SqlTab sends the setting again before
 * each statement. SqlReadOnly refuses statements that would write or undo it, before the
 * connection is even opened; the app refuses them first.
 *
 * Connection options (#140): a Unix socket, a charset, TLS (a mode and the CA, client
 * certificate, and key files, which are paths where this PHP runs; Runlet never reads them),
 * extra DSN options, and init statements; SQL Server (pdo_sqlsrv, else pdo_dblib) and a
 * custom PDO DSN. No option carries a password: keys that look like one are refused here
 * too. Init statements run after the read-only setting (so the database refuses writes in
 * them), and the setting is sent and checked again after them.
 *
 * SSH tunnels (#143): `tunnel` carries the local port of a forward on an SSH profile's shared
 * connection, opened from this Mac. PHP connects to 127.0.0.1 on that port; the host stays the
 * server's name, so PostgreSQL gets it as `host` (for TLS verify-full) with
 * `hostaddr=127.0.0.1`. MySQL and SQL Server connect to 127.0.0.1 and check a certificate
 * against that address.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class SqlConnect
{
    private const DRIVERS = ['mysql', 'pgsql', 'sqlite', 'sqlsrv', 'custom'];
    private const READ_ONLY_DRIVERS = ['mysql', 'pgsql', 'sqlite'];
    private const TLS_MODES = ['disable', 'prefer', 'require', 'verify-ca', 'verify-full'];
    /** DSN keys each driver sets from its own fields, so extra options can't. */
    private const MANAGED_OPTIONS = [
        'pgsql' => ['host', 'port', 'dbname', 'user', 'sslmode', 'sslrootcert', 'sslcert', 'sslkey', 'client_encoding', 'connect_timeout'],
        'sqlsrv' => ['server', 'database', 'uid', 'encrypt', 'trustservercertificate', 'logintimeout'],
    ];
    private const MAX_INIT_STATEMENTS = 20;

    /**
     * @var array{id: string, name: string, driver: string, host: string, port: int|null, database: string, user: string, timeout: int, summary: string, readOnly: bool, socket: string, charset: string, tls: array{mode: string, ca: string, cert: string, key: string}, init: string[], options: array<int, array{0: string, 1: string}>, dsn: string, place: string, tunnel: array{port: int, via: string}}|null
     */
    private static $definition;
    /** @var string|null The password, until the connection is open. */
    private static $password;
    /** @var \PDO|null */
    private static $pdo;
    /** @var string|null The PDO driver that opened the connection (`dblib` for SQL Server through FreeTDS). */
    private static $pdoDriver;
    /** @var float|null */
    private static $connectMs;

    /**
     * Takes the saved connection from the runner request. Called by Runner::main() before
     * the bootstrap; the caller removes it from the request.
     *
     * @param array<string, mixed> $connection
     */
    public static function configure(array $connection): void
    {
        $password = isset($connection['password']) && is_string($connection['password']) ? $connection['password'] : null;
        unset($connection['password']);
        $tls = is_array($connection['tls'] ?? null) ? $connection['tls'] : [];
        $init = [];
        foreach (is_array($connection['init'] ?? null) ? $connection['init'] : [] as $statement) {
            if (is_string($statement) && trim($statement) !== '') {
                $init[] = $statement;
            }
        }
        $tunnel = is_array($connection['tunnel'] ?? null) ? $connection['tunnel'] : [];
        $options = [];
        foreach (is_array($connection['options'] ?? null) ? $connection['options'] : [] as $option) {
            if (is_array($option) && isset($option[0], $option[1]) && is_string($option[0]) && is_string($option[1])) {
                $options[] = [$option[0], $option[1]];
            }
        }
        self::$definition = [
            'id' => (string) ($connection['id'] ?? ''),
            'name' => (string) ($connection['name'] ?? ''),
            'driver' => (string) ($connection['driver'] ?? ''),
            'host' => (string) ($connection['host'] ?? ''),
            'port' => isset($connection['port']) ? (int) $connection['port'] : null,
            'database' => (string) ($connection['database'] ?? ''),
            'user' => (string) ($connection['user'] ?? ''),
            'timeout' => max(1, min(300, (int) ($connection['timeout'] ?? 10))),
            'summary' => (string) ($connection['summary'] ?? ''),
            'readOnly' => ($connection['readOnly'] ?? false) === true,
            'socket' => (string) ($connection['socket'] ?? ''),
            'charset' => (string) ($connection['charset'] ?? ''),
            'tls' => [
                'mode' => (string) ($tls['mode'] ?? ''),
                'ca' => (string) ($tls['ca'] ?? ''),
                'cert' => (string) ($tls['cert'] ?? ''),
                'key' => (string) ($tls['key'] ?? ''),
            ],
            'init' => $init,
            'options' => $options,
            'dsn' => (string) ($connection['dsn'] ?? ''),
            // #142: "mac" when this PHP runs on the user's Mac for the connection.
            'place' => ($connection['place'] ?? '') === 'mac' ? 'mac' : 'target',
            // #143: the local forward's port (0: no tunnel) and the SSH profile's name.
            'tunnel' => [
                'port' => max(0, min(65535, (int) ($tunnel['port'] ?? 0))),
                'via' => (string) ($tunnel['via'] ?? ''),
            ],
        ];
        self::$password = $password;
        if ($password !== null && $password !== '') {
            Channel::addSecret($password);
        }
    }

    public static function isConfigured(): bool
    {
        return self::$definition !== null;
    }

    /** The saved connection's name. */
    public static function name(): string
    {
        return self::$definition['name'] ?? '';
    }

    /** The saved connection is read-only (#139). */
    public static function isReadOnly(): bool
    {
        return (self::$definition['readOnly'] ?? false) === true;
    }

    /**
     * Where results say they came from: `saved connection "Reporting" (pgsql, db:5432/reports)`,
     * with `, read-only session` for a read-only one (#139).
     */
    public static function origin(): string
    {
        $definition = self::$definition ?? [];
        $summary = (string) ($definition['summary'] ?? '');

        return 'saved connection "' . ($definition['name'] ?? '') . '"' . ($summary === '' ? '' : ' (' . $summary . ')') . (self::isReadOnly() ? ', read-only session' : '');
    }

    /** Whether this PHP opens the connection from the user's Mac (#142) rather than on the target. */
    public static function onThisMac(): bool
    {
        return (self::$definition['place'] ?? '') === 'mac';
    }

    /** "This Mac's PHP 8.5.8" or "This target's PHP 8.4.1", for messages. */
    private static function whosePhp(): string
    {
        return (self::onThisMac() ? 'This Mac\'s PHP ' : 'This target\'s PHP ') . PHP_VERSION;
    }

    /** "this Mac" or "this target", for messages. */
    private static function here(): string
    {
        return self::onThisMac() ? 'this Mac' : 'this target';
    }

    /** What to do about a missing driver from this Mac (#142): Runlet's PHP has them. */
    private static function macDriverHint(string $driver): string
    {
        if (!self::onThisMac()) {
            return '';
        }

        return in_array($driver, ['mysql', 'pgsql', 'sqlite'], true)
            ? ' Download Runlet\'s PHP in Settings ▸ PHP: it has pdo_mysql, pdo_pgsql, and pdo_sqlite, and Runlet uses it for connections from this Mac.'
            : ' Runlet\'s PHP doesn\'t have it either: install the driver in this Mac\'s default PHP (Settings ▸ PHP), or open the connection from the target.';
    }

    /** The saved connection's driver (`mysql`, `pgsql`, `sqlite`, `sqlsrv`, or `custom`). */
    public static function driverName(): ?string
    {
        return self::$definition['driver'] ?? null;
    }

    /** The open connection; opens it on first use. */
    public static function pdo(): \PDO
    {
        if (self::$pdo === null) {
            $started = hrtime(true);
            try {
                self::$pdo = self::connect();
            } finally {
                // Opened or not, this process never needs the password again.
                self::$password = null;
            }
            self::$connectMs = round((hrtime(true) - $started) / 1e6, 3);
        }

        return self::$pdo;
    }

    /**
     * Test Connection: opens the connection and reports the server's version, the current
     * database and user, one round trip, and whether TLS is in use (#140). Runs only Runlet's
     * own fixed queries, after the connection's init statements.
     *
     * @return array<string, mixed>
     */
    public static function test(): array
    {
        $pdo = self::pdo();
        $driver = self::$pdoDriver ?? (string) self::driverName();
        $version = null;
        try {
            $version = (string) $pdo->getAttribute(\PDO::ATTR_SERVER_VERSION);
        } catch (\Throwable $error) {
            $version = null;
        }
        $started = hrtime(true);
        $pdo->query('SELECT 1')->fetchAll();
        $roundTrip = round((hrtime(true) - $started) / 1e6, 3);
        $database = null;
        $user = null;
        try {
            if ($driver === 'mysql') {
                $row = $pdo->query('SELECT DATABASE(), CURRENT_USER()')->fetch(\PDO::FETCH_NUM);
                [$database, $user] = is_array($row) ? $row : [null, null];
            } elseif ($driver === 'pgsql') {
                $row = $pdo->query('SELECT current_database(), current_user')->fetch(\PDO::FETCH_NUM);
                [$database, $user] = is_array($row) ? $row : [null, null];
            } elseif ($driver === 'sqlsrv' || $driver === 'dblib') {
                $row = $pdo->query('SELECT DB_NAME(), SUSER_SNAME()')->fetch(\PDO::FETCH_NUM);
                [$database, $user] = is_array($row) ? $row : [null, null];
            } elseif ($driver === 'sqlite' && self::driverName() === 'sqlite') {
                $path = (string) (self::$definition['database'] ?? '');
                $real = $path === ':memory:' ? false : realpath($path);
                $database = $real === false ? $path : $real;
            }
        } catch (\Throwable $error) {
            // Version and round trip are enough; the names are a courtesy.
        }
        $definition = self::$definition ?? [];

        return array_filter([
            'driver' => self::driverName() === 'custom' ? $driver : self::driverName(),
            // SQL Server opened through pdo_dblib (FreeTDS) rather than pdo_sqlsrv.
            'pdoDriver' => $driver === 'dblib' ? 'dblib' : null,
            'serverVersion' => $version,
            'database' => $database === null ? null : (string) $database,
            'user' => $user === null ? null : (string) $user,
            'connectMs' => self::$connectMs,
            'roundTripMs' => $roundTrip,
            'phpVersion' => PHP_VERSION,
            // connect() checked that the database took the read-only setting.
            'readOnly' => self::isReadOnly() ? true : null,
            'initStatements' => ($definition['init'] ?? []) === [] ? null : count($definition['init']),
            // #142: Test Connection reports the PHP's drivers.
            'pdoDrivers' => array_values(\PDO::getAvailableDrivers()),
        ] + self::tlsInfo($pdo, $driver), static function ($value): bool {
            return $value !== null;
        });
    }

    /**
     * Whether the open connection is encrypted, as the server reports it: `tls` (bool),
     * `tlsVersion`, `tlsCipher`. Empty when the driver can't tell.
     *
     * @return array<string, mixed>
     */
    private static function tlsInfo(\PDO $pdo, string $driver): array
    {
        try {
            if ($driver === 'mysql') {
                $status = $pdo->query("SHOW SESSION STATUS WHERE Variable_name IN ('Ssl_version', 'Ssl_cipher')")->fetchAll(\PDO::FETCH_KEY_PAIR);
                $cipher = (string) ($status['Ssl_cipher'] ?? '');

                return ['tls' => $cipher !== '', 'tlsVersion' => $cipher === '' ? null : (string) ($status['Ssl_version'] ?? ''), 'tlsCipher' => $cipher === '' ? null : $cipher];
            }
            if ($driver === 'pgsql') {
                $row = $pdo->query('SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid()')->fetch(\PDO::FETCH_NUM);
                if (!is_array($row)) {
                    return [];
                }
                $on = in_array(strtolower(var_export($row[0], true)), ['true', "'t'", "'1'", '1'], true);

                return ['tls' => $on, 'tlsVersion' => $on ? (string) $row[1] : null, 'tlsCipher' => $on ? (string) $row[2] : null];
            }
            if ($driver === 'sqlsrv' || $driver === 'dblib') {
                $value = $pdo->query('SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID')->fetchColumn();

                return $value === false ? [] : ['tls' => strtoupper((string) $value) === 'TRUE'];
            }
        } catch (\Throwable $error) {
            // The user may not see the view (SQL Server needs VIEW SERVER STATE).
        }

        return [];
    }

    /**
     * How the connection will be opened: the PDO DSN, the PDO attributes (by constant name),
     * and the PDO driver. Never the password (PDO gets it as its own argument). Throws
     * SqlConnectionFailed when the definition can't be expressed or this PHP lacks the
     * driver. `$available` defaults to this PHP's PDO drivers.
     *
     * @param string[]|null $available
     * @return array{dsn: string, attributes: array<string, array{0: int, 1: mixed}>, pdoDriver: string}
     */
    public static function plan(?array $available = null): array
    {
        $definition = self::$definition;
        if ($definition === null) {
            throw new SqlConnectionFailed('No saved connection was sent with this run.');
        }
        $name = '"' . $definition['name'] . '"';
        $driver = $definition['driver'];
        if (!in_array($driver, self::DRIVERS, true)) {
            throw new SqlConnectionFailed('The saved connection ' . $name . ' uses the ' . $driver . ' driver, which this Runlet doesn\'t support.');
        }
        if ($available === null) {
            if (!class_exists('PDO', false)) {
                throw new SqlConnectionFailed(self::whosePhp() . ' has no PDO extension, so it can\'t open the saved connection ' . $name . '.' . self::macDriverHint((string) $driver));
            }
            $available = \PDO::getAvailableDrivers();
        }
        $has = 'It has: ' . ($available === [] ? 'none' : implode(', ', $available)) . '.';
        if ($definition['readOnly'] && !in_array($driver, self::READ_ONLY_DRIVERS, true)) {
            throw new SqlConnectionFailed('Runlet can\'t make the session of the saved connection ' . $name . ' read-only (' . ($driver === 'custom' ? 'a custom DSN' : 'SQL Server') . ' has no read-only session it can enforce), so nothing ran.');
        }
        $tls = $definition['tls'];
        if ($tls['mode'] !== '' && !in_array($tls['mode'], self::TLS_MODES, true)) {
            throw new SqlConnectionFailed('The saved connection ' . $name . ' asks for the TLS mode "' . $tls['mode'] . '", which this Runlet doesn\'t know.');
        }
        self::checkOptions($driver, $definition['options']);
        if ($definition['tunnel']['port'] > 0) {
            self::checkTunnel($definition);
        }
        $timeout = $definition['timeout'];
        $attributes = ['PDO::ATTR_TIMEOUT' => [\PDO::ATTR_TIMEOUT, $timeout]];

        switch ($driver) {
            case 'sqlite':
                self::requireDriver('sqlite', $available, $has);
                $database = $definition['database'];
                if ($database === '' || strpos($database, "\0") !== false) {
                    throw new SqlConnectionFailed('The saved connection has no SQLite file.');
                }
                if ($database !== ':memory:' && !is_file($database)) {
                    throw new SqlConnectionFailed('The SQLite file ' . $database . ' doesn\'t exist on ' . self::here() . (substr($database, 0, 1) === '/' ? '' : ' (a relative path starts in ' . (getcwd() ?: 'the project directory') . ')') . '. Runlet opens existing files only.');
                }
                if ($definition['readOnly']) {
                    // #139: SQLite opens the file read-only (PHP 7.3+), so no statement can write to it.
                    $flags = self::constant(['Pdo\Sqlite::ATTR_OPEN_FLAGS', 'PDO::SQLITE_ATTR_OPEN_FLAGS']);
                    $readOnly = self::constant(['Pdo\Sqlite::OPEN_READONLY', 'PDO::SQLITE_OPEN_READONLY']);
                    if ($flags !== null && $readOnly !== null) {
                        $attributes[$flags[0]] = [$flags[1], $readOnly[1]];
                    }
                }

                return ['dsn' => 'sqlite:' . $database, 'attributes' => $attributes, 'pdoDriver' => 'sqlite'];

            case 'mysql':
                self::requireDriver('mysql', $available, $has);
                $dsn = 'mysql:' . self::address($definition, false) . self::databasePart($definition, ';dbname=', false);
                $charset = $definition['charset'] === '' ? 'utf8mb4' : $definition['charset'];
                self::checkCharset($charset);
                $dsn .= ';charset=' . $charset;

                return ['dsn' => $dsn, 'attributes' => $attributes + self::mysqlTls($definition), 'pdoDriver' => 'mysql'];

            case 'pgsql':
                self::requireDriver('pgsql', $available, $has);
                $dsn = 'pgsql:' . self::address($definition, true) . self::databasePart($definition, ';dbname=', true);
                if ($tls['mode'] !== '') {
                    $dsn .= ';sslmode=' . $tls['mode'];
                    if ($tls['mode'] !== 'disable') {
                        foreach (['ca' => 'sslrootcert', 'cert' => 'sslcert', 'key' => 'sslkey'] as $field => $keyword) {
                            if ($tls[$field] !== '') {
                                $dsn .= ';' . $keyword . '=' . self::libpqQuote(self::checkPath($tls[$field], self::fileLabel($field)));
                            }
                        }
                    }
                }
                if ($definition['charset'] !== '') {
                    $dsn .= ';client_encoding=' . self::libpqQuote(self::checkCharset($definition['charset']));
                }
                foreach ($definition['options'] as [$key, $value]) {
                    $dsn .= ';' . $key . '=' . self::libpqQuote($value);
                }

                return ['dsn' => $dsn, 'attributes' => $attributes, 'pdoDriver' => 'pgsql'];

            case 'sqlsrv':
                // Microsoft's pdo_sqlsrv, else pdo_dblib (FreeTDS).
                $pdoDriver = in_array('sqlsrv', $available, true) ? 'sqlsrv' : (in_array('dblib', $available, true) ? 'dblib' : null);
                if ($pdoDriver === null) {
                    throw new SqlConnectionFailed(self::whosePhp() . ' has neither pdo_sqlsrv nor pdo_dblib, which SQL Server needs. ' . $has . self::macDriverHint('sqlsrv'));
                }
                $host = self::checkHost($definition['host']);
                $port = (int) ($definition['port'] ?? 1433);
                if ($definition['tunnel']['port'] > 0) {
                    // #143: the SSH tunnel's local end.
                    $host = '127.0.0.1';
                    $port = $definition['tunnel']['port'];
                }
                if ($pdoDriver === 'dblib') {
                    if ($tls['mode'] !== '') {
                        throw new SqlConnectionFailed((self::onThisMac() ? 'This Mac\'s PHP' : 'This target\'s PHP') . ' opens SQL Server with pdo_dblib (FreeTDS), which takes TLS settings from freetds.conf ("encryption"), not from Runlet. Set the connection\'s TLS to "Driver default", or install pdo_sqlsrv. Nothing ran.');
                    }
                    $dsn = 'dblib:host=' . $host . ':' . $port . self::databasePart($definition, ';dbname=', false, true) . ';charset=UTF-8';
                    foreach ($definition['options'] as [$key, $value]) {
                        $dsn .= ';' . $key . '=' . $value;
                    }

                    return ['dsn' => $dsn, 'attributes' => $attributes, 'pdoDriver' => 'dblib'];
                }
                // pdo_sqlsrv rejects PDO::ATTR_TIMEOUT; its DSN has LoginTimeout.
                $dsn = 'sqlsrv:Server=' . $host . ',' . $port . self::databasePart($definition, ';Database=', false, true) . ';LoginTimeout=' . $timeout;
                if ($tls['mode'] === 'disable') {
                    $dsn .= ';Encrypt=no';
                } elseif ($tls['mode'] === 'require') {
                    $dsn .= ';Encrypt=yes;TrustServerCertificate=yes';
                } elseif ($tls['mode'] === 'verify-full') {
                    $dsn .= ';Encrypt=yes;TrustServerCertificate=no';
                } elseif ($tls['mode'] !== '') {
                    throw new SqlConnectionFailed('SQL Server\'s driver can\'t express the TLS mode ' . $tls['mode'] . ' (it checks the host name whenever it checks the certificate, and it can\'t fall back). Choose disable, require, or verify-full.');
                }
                foreach ($definition['options'] as [$key, $value]) {
                    $dsn .= ';' . $key . '=' . $value;
                }

                return ['dsn' => $dsn, 'attributes' => [], 'pdoDriver' => 'sqlsrv'];

            default: // custom
                $dsn = $definition['dsn'];
                $problem = self::customDsnProblem($dsn);
                if ($problem !== null) {
                    throw new SqlConnectionFailed('The saved connection ' . $name . '\'s DSN ' . $problem);
                }
                $prefix = strtolower(substr($dsn, 0, (int) strpos($dsn, ':')));
                if (!in_array($prefix, $available, true)) {
                    throw new SqlConnectionFailed(self::whosePhp() . ' has no pdo_' . $prefix . ' driver for the DSN. ' . $has . self::macDriverHint($prefix));
                }

                return ['dsn' => $dsn, 'attributes' => $prefix === 'sqlsrv' ? [] : $attributes, 'pdoDriver' => $prefix];
        }
    }

    /**
     * Why a custom DSN can't be used, or null: it must start with a PDO driver prefix, and it
     * can't carry a password (or point PDO at a file or URL that holds the DSN).
     */
    public static function customDsnProblem(string $dsn): ?string
    {
        if (trim($dsn) === '') {
            return 'is empty.';
        }
        if (preg_match('/[\x00-\x1f\x7f]/', $dsn) === 1) {
            return 'can\'t contain line breaks or control characters.';
        }
        if (preg_match('/^[A-Za-z][A-Za-z0-9_]*:/', $dsn) !== 1) {
            return 'must start with a PDO driver name and a colon, such as oci: or odbc:.';
        }
        if (stripos($dsn, 'uri:') === 0) {
            return 'can\'t be a uri: DSN (Runlet doesn\'t let PDO read the DSN from a file or URL). Paste the DSN itself.';
        }
        if (preg_match('/(^|[;:\s])\s*(password|passwd|pwd|sslpassword)\s*=/i', $dsn) === 1 || preg_match('#://[^/@\s;]*:[^/@\s;]*@#', $dsn) === 1) {
            return 'contains a password. Runlet keeps passwords only in the Keychain: put it in the Password field.';
        }

        return null;
    }

    /**
     * MySQL's TLS attributes (#140). mysqlnd encrypts only when one of the SSL attributes is
     * set, and then checks the certificate and the host name together unless
     * MYSQL_ATTR_SSL_VERIFY_SERVER_CERT is false; so it has disable, require, and verify-full,
     * and no prefer or verify-ca. connect() checks Ssl_cipher afterwards.
     *
     * @param array<string, mixed> $definition
     * @return array<string, array{0: int, 1: mixed}>
     */
    private static function mysqlTls(array $definition): array
    {
        $tls = $definition['tls'];
        $mode = $tls['mode'];
        if ($mode === '' || $mode === 'disable') {
            return [];
        }
        if ($mode === 'prefer' || $mode === 'verify-ca') {
            throw new SqlConnectionFailed('MySQL\'s PDO driver can\'t express the TLS mode ' . $mode . ': it either requires TLS or doesn\'t use it, and it checks the host name whenever it checks the certificate. Choose disable, require, or verify-full.');
        }
        $attributes = [];
        $set = static function (string $suffix, $value) use (&$attributes): void {
            $constant = self::constant(['Pdo\Mysql::ATTR_' . $suffix, 'PDO::MYSQL_ATTR_' . $suffix]);
            if ($constant === null) {
                throw new SqlConnectionFailed(self::whosePhp() . ' has no PDO::MYSQL_ATTR_' . $suffix . ', so it can\'t open this connection with TLS (it needs PHP 7.1.4 or later with mysqlnd).');
            }
            $attributes[$constant[0]] = [$constant[1], $value];
        };
        if ($tls['ca'] !== '') {
            $set('SSL_CA', self::checkPath($tls['ca'], 'CA file'));
        } elseif ($mode === 'require') {
            // An empty CA turns TLS on; nothing is verified, so nothing is loaded.
            $set('SSL_CA', '');
        } else {
            // verify-full without a CA file: this PHP's OpenSSL default certificates.
            [$file, $directory] = self::systemCertificates();
            if ($file !== null) {
                $set('SSL_CA', $file);
            } elseif ($directory !== null) {
                $set('SSL_CAPATH', $directory);
            } else {
                throw new SqlConnectionFailed('Verifying the server needs a CA file, and this target\'s PHP has no default one (openssl.cafile). Set the connection\'s CA file. Nothing ran.');
            }
        }
        if ($tls['cert'] !== '') {
            $set('SSL_CERT', self::checkPath($tls['cert'], 'client certificate'));
        }
        if ($tls['key'] !== '') {
            $set('SSL_KEY', self::checkPath($tls['key'], 'client key'));
        }
        $set('SSL_VERIFY_SERVER_CERT', $mode === 'verify-full');

        return $attributes;
    }

    /**
     * This PHP's default CA file and directory (openssl.cafile/capath, else OpenSSL's
     * defaults), when they exist.
     *
     * @return array{0: string|null, 1: string|null}
     */
    private static function systemCertificates(): array
    {
        if (!function_exists('openssl_get_cert_locations')) {
            return [null, null];
        }
        $locations = openssl_get_cert_locations();
        $file = null;
        foreach ([(string) ($locations['ini_cafile'] ?? ''), (string) ($locations['default_cert_file'] ?? '')] as $candidate) {
            if ($candidate !== '' && is_file($candidate)) {
                $file = $candidate;
                break;
            }
        }
        $directory = null;
        foreach ([(string) ($locations['ini_capath'] ?? ''), (string) ($locations['default_cert_dir'] ?? '')] as $candidate) {
            if ($candidate !== '' && is_dir($candidate)) {
                $directory = $candidate;
                break;
            }
        }

        return [$file, $directory];
    }

    /**
     * `host=…;port=…`, or the Unix socket (MySQL `unix_socket=`; PostgreSQL `host=` with the
     * socket's directory, and the port that names the socket file).
     *
     * @param array<string, mixed> $definition
     */
    private static function address(array $definition, bool $pgsql): string
    {
        $socket = (string) $definition['socket'];
        $port = (int) ($definition['port'] ?? ($pgsql ? 5432 : 3306));
        if ($socket !== '') {
            self::checkPath($socket, 'socket', false);

            return $pgsql ? 'host=' . self::libpqQuote($socket) . ';port=' . $port : 'unix_socket=' . $socket;
        }
        $host = self::checkHost((string) $definition['host']);
        $tunnel = (int) ($definition['tunnel']['port'] ?? 0);
        if ($tunnel > 0) {
            // #143: connect to the SSH tunnel's local end. libpq still gets the server's name
            // as host, for TLS verification (verify-full) and its messages.
            return $pgsql
                ? 'host=' . trim($host, '[]') . ';hostaddr=127.0.0.1;port=' . $tunnel
                : 'host=127.0.0.1;port=' . $tunnel;
        }

        // libpq takes a bracket-less IPv6 address.
        return 'host=' . ($pgsql ? trim($host, '[]') : $host) . ';port=' . $port;
    }

    /**
     * #143: a connection through an SSH tunnel forwards a host and port, so it can't use a
     * socket, an SQLite file, or a custom DSN, and no option may send libpq elsewhere.
     *
     * @param array<string, mixed> $definition
     */
    private static function checkTunnel(array $definition): void
    {
        $name = '"' . $definition['name'] . '"';
        if (!in_array($definition['driver'], ['mysql', 'pgsql', 'sqlsrv'], true)) {
            throw new SqlConnectionFailed('The saved connection ' . $name . ' can\'t go through an SSH tunnel: a tunnel forwards a host and port. Nothing ran.');
        }
        if ((string) $definition['socket'] !== '') {
            throw new SqlConnectionFailed('The saved connection ' . $name . ' goes through an SSH tunnel, which forwards a host and port, not a Unix socket. Nothing ran.');
        }
        foreach ($definition['options'] as [$key, $value]) {
            if (strtolower($key) === 'hostaddr') {
                throw new SqlConnectionFailed('The saved connection ' . $name . ' goes through an SSH tunnel, so its "' . $key . '" option is set by the tunnel (127.0.0.1). Remove the option. Nothing ran.');
            }
        }
    }

    /** @param array<string, mixed> $definition */
    private static function databasePart(array $definition, string $prefix, bool $quote, bool $braces = false): string
    {
        $database = (string) $definition['database'];
        if ($database === '') {
            return '';
        }
        if (preg_match('/[;\'"\\\\\x00-\x1f]/', $database) === 1 || ($braces && strpbrk($database, '{}') !== false)) {
            throw new SqlConnectionFailed('The saved connection\'s database name can\'t contain ";", quotes' . ($braces ? ', braces' : '') . ', or control characters.');
        }

        return $prefix . ($quote ? "'" . $database . "'" : $database);
    }

    private static function checkHost(string $host): string
    {
        if ($host === '' || preg_match('/^[A-Za-z0-9._:%\[\]-]+$/', $host) !== 1 || $host[0] === '-') {
            throw new SqlConnectionFailed('The saved connection\'s host "' . $host . '" isn\'t a host name or IP address.');
        }

        return $host;
    }

    private static function checkCharset(string $charset): string
    {
        if (preg_match('/^[A-Za-z0-9_-]{1,40}$/', $charset) !== 1) {
            throw new SqlConnectionFailed('The saved connection\'s charset "' . $charset . '" isn\'t a character set name.');
        }

        return $charset;
    }

    /**
     * A path where this PHP runs (a socket, a CA file, a client certificate or key): absolute,
     * and nothing that could end or quote a DSN value. Files must exist and be readable; Runlet
     * doesn't open them, the driver does.
     */
    private static function checkPath(string $path, string $what, bool $file = true): string
    {
        if ($path === '' || $path[0] !== '/' || preg_match('/[;\'"\\\\\x00-\x1f]/', $path) === 1) {
            throw new SqlConnectionFailed('The ' . $what . ' "' . $path . '" must be an absolute path without ";", quotes, backslashes, or control characters.');
        }
        if ($file && !is_readable($path)) {
            throw new SqlConnectionFailed('The ' . $what . ' ' . $path . ' doesn\'t exist on ' . self::here() . ', or its PHP can\'t read it. Nothing ran.');
        }

        return $path;
    }

    private static function fileLabel(string $field): string
    {
        return $field === 'ca' ? 'CA file' : ($field === 'cert' ? 'client certificate' : 'client key');
    }

    /** A libpq connection value in single quotes (pdo_pgsql turns every ";" into a space). */
    private static function libpqQuote(string $value): string
    {
        return "'" . str_replace(['\\', "'"], ['\\\\', "\\'"], $value) . "'";
    }

    /**
     * Extra DSN options (#140): PostgreSQL's libpq keywords and SQL Server's DSN keywords.
     * Refused: other drivers, keys that look like a password, keys Runlet sets from the
     * connection's fields, and values that could end the DSN entry.
     *
     * @param array<int, array{0: string, 1: string}> $options
     */
    private static function checkOptions(string $driver, array $options): void
    {
        if ($options === []) {
            return;
        }
        if (!isset(self::MANAGED_OPTIONS[$driver])) {
            throw new SqlConnectionFailed('The ' . $driver . ' driver takes no extra DSN options.');
        }
        foreach ($options as [$key, $value]) {
            if (preg_match('/^[A-Za-z][A-Za-z0-9_]{0,63}$/', $key) !== 1) {
                throw new SqlConnectionFailed('The DSN option "' . $key . '" isn\'t a keyword.');
            }
            if (preg_match('/pass|pwd/i', $key) === 1) {
                throw new SqlConnectionFailed('The DSN option "' . $key . '" looks like a password. Runlet keeps passwords only in the Keychain: put it in the Password field.');
            }
            if (in_array(strtolower($key), self::MANAGED_OPTIONS[$driver], true)) {
                throw new SqlConnectionFailed('The DSN option "' . $key . '" is set from the connection\'s own fields.');
            }
            if (preg_match($driver === 'sqlsrv' ? '/[;{}\x00-\x1f]/' : '/[;\x00-\x1f]/', $value) === 1) {
                throw new SqlConnectionFailed('The value of the DSN option "' . $key . '" can\'t contain ";"' . ($driver === 'sqlsrv' ? ', braces,' : '') . ' or control characters.');
            }
        }
    }

    /** @param string[] $available */
    private static function requireDriver(string $driver, array $available, string $has): void
    {
        if (!in_array($driver, $available, true)) {
            throw new SqlConnectionFailed(self::whosePhp() . ' has no pdo_' . $driver . ' driver. ' . $has . self::macDriverHint($driver));
        }
    }

    /**
     * Opens the connection. It takes no arguments, so neither the password nor the DSN is
     * ever in a stack frame; PDO's exception is replaced by one with its message only.
     */
    private static function connect(): \PDO
    {
        $definition = self::$definition;
        if ($definition === null) {
            throw new SqlConnectionFailed('No saved connection was sent with this run.');
        }
        $name = '"' . $definition['name'] . '"';
        $plan = self::plan();
        // Init statements are checked before anything is sent.
        $count = count($definition['init']);
        if ($count > self::MAX_INIT_STATEMENTS) {
            throw new SqlConnectionFailed('The saved connection ' . $name . ' has ' . $count . ' init statements; Runlet runs at most ' . self::MAX_INIT_STATEMENTS . '. Nothing ran.');
        }
        foreach ($definition['init'] as $index => $statement) {
            $why = SqlReadOnly::initRefusal($statement, $definition['driver'], $definition['readOnly']);
            if ($why !== null) {
                throw new SqlConnectionFailed('Init statement ' . ($index + 1) . ' of the saved connection ' . $name . ' ' . $why . ', so Runlet didn\'t connect. Nothing ran.');
            }
        }
        $options = [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION];
        foreach ($plan['attributes'] as [$key, $value]) {
            $options[$key] = $value;
        }
        $warnings = [];
        set_error_handler(static function (int $severity, string $message) use (&$warnings): bool {
            $warnings[] = $message;

            return true;
        });
        $message = '';
        $pdo = null;
        try {
            $pdo = new \PDO($plan['dsn'], $definition['user'] === '' ? null : $definition['user'], self::$password, $options);
        } catch (\Throwable $error) {
            $message = $error->getMessage();
        } finally {
            restore_error_handler();
        }
        if ($pdo === null) {
            if ($message === '' && $warnings !== []) {
                $message = implode(' ', $warnings);
            }
            // #143: through a tunnel, the SSH server opens the TCP connection to the database.
            $hint = $definition['tunnel']['port'] > 0
                ? ' The SSH server of "' . $definition['tunnel']['via'] . '" connects to the database for the tunnel, so the host and port are as that server sees them; check it can reach them.'
                : '';
            // Thrown outside the catch, with no previous exception: nothing of PDO's trace stays.
            throw new SqlConnectionFailed(Channel::scrub('Runlet could not open the saved connection ' . $name . ' (' . $definition['summary'] . '): ' . $message . $hint));
        }
        self::$pdoDriver = $plan['pdoDriver'];
        $where = $name . ' (' . $definition['summary'] . ')';
        if ($plan['pdoDriver'] === 'mysql' && in_array($definition['tls']['mode'], ['require', 'verify-full'], true)) {
            // #140: refuse to go on unencrypted, whatever mysqlnd did.
            $cipher = '';
            try {
                $row = $pdo->query("SHOW SESSION STATUS LIKE 'Ssl_cipher'")->fetch(\PDO::FETCH_NUM);
                $cipher = is_array($row) ? (string) ($row[1] ?? '') : '';
            } catch (\Throwable $error) {
                $cipher = '';
            }
            if ($cipher === '') {
                $pdo = null;
                throw new SqlConnectionFailed('The saved connection ' . $where . ' asks for TLS (' . $definition['tls']['mode'] . '), but the server didn\'t encrypt the session, so nothing ran.');
            }
        }
        if ($definition['readOnly']) {
            $problem = self::makeReadOnly($pdo, $definition['driver'], true);
            if ($problem !== null) {
                $pdo = null;
                throw new SqlConnectionFailed(Channel::scrub('Runlet could not make the session of the read-only connection ' . $where . ' read-only, so nothing ran: ' . $problem));
            }
        }
        foreach ($definition['init'] as $index => $statement) {
            try {
                $result = $pdo->query($statement);
                if ($result !== false) {
                    $result->closeCursor();
                }
            } catch (\Throwable $error) {
                $pdo = null;
                throw new SqlConnectionFailed(Channel::scrub('Init statement ' . ($index + 1) . ' of the saved connection ' . $where . ' failed, so nothing of yours ran: ' . $error->getMessage()));
            }
        }
        if ($definition['readOnly'] && $definition['init'] !== []) {
            // Whatever the init statements did, the session is read-only again, and checked.
            $problem = self::makeReadOnly($pdo, $definition['driver'], true);
            if ($problem !== null) {
                $pdo = null;
                throw new SqlConnectionFailed(Channel::scrub('After its init statements, the session of the read-only connection ' . $where . ' isn\'t read-only, so nothing ran: ' . $problem));
            }
        }

        return $pdo;
    }

    /**
     * Read-only connections (#139): sends the driver's read-only setting again. SqlTab calls
     * it before each statement, so a statement that slipped past the refusals can't leave the
     * session writable for the next one. A failure stops the run.
     */
    public static function enforceReadOnly(): void
    {
        if (!self::isReadOnly() || self::$pdo === null) {
            return;
        }
        $problem = self::makeReadOnly(self::$pdo, (string) self::driverName(), false);
        if ($problem !== null) {
            throw new SqlConnectionFailed('Runlet could not keep the session of the read-only connection "' . self::name() . '" read-only, so it stopped: ' . $problem);
        }
    }

    /**
     * Sends the driver's read-only setting; with `$verify`, asks the database whether it took
     * it. Returns what went wrong, or null.
     */
    private static function makeReadOnly(\PDO $pdo, string $driver, bool $verify): ?string
    {
        $statements = [
            'mysql' => ['SET SESSION TRANSACTION READ ONLY', ['SELECT @@session.transaction_read_only', 'SELECT @@session.tx_read_only']],
            'pgsql' => ['SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY', ['SHOW default_transaction_read_only']],
            'sqlite' => ['PRAGMA query_only = ON', ['PRAGMA query_only']],
        ];
        if (!isset($statements[$driver])) {
            return 'the ' . $driver . ' driver has no read-only session.';
        }
        [$set, $checks] = $statements[$driver];
        try {
            $pdo->exec($set);
        } catch (\Throwable $error) {
            return $set . ' failed: ' . $error->getMessage() . ($driver === 'mysql' ? ' (MySQL 5.6.5 and MariaDB 10.0 or later have read-only sessions.)' : '');
        }
        if (!$verify) {
            return null;
        }
        $last = '';
        foreach ($checks as $check) {
            try {
                $statement = $pdo->query($check);
                $value = $statement === false ? false : $statement->fetchColumn();
                if ($statement !== false) {
                    $statement->closeCursor();
                }
            } catch (\Throwable $error) {
                // MySQL before 5.7.20 and MariaDB before 11.1 call it tx_read_only.
                $last = $error->getMessage();
                continue;
            }
            if (in_array(strtolower((string) $value), ['1', 'on', 'true'], true)) {
                return null;
            }

            return 'the database says the session is not read-only (' . $check . ' = ' . var_export($value, true) . ').';
        }

        return 'Runlet could not check it: ' . $last;
    }

    /**
     * The first defined class or PDO constant, as [name, value] (PHP 8.4 moved driver
     * constants to Pdo\Mysql and Pdo\Sqlite, and later deprecates the PDO:: ones).
     *
     * @param string[] $names
     * @return array{0: string, 1: int}|null
     */
    private static function constant(array $names): ?array
    {
        foreach ($names as $name) {
            if (defined($name)) {
                return [$name, (int) constant($name)];
            }
        }

        return null;
    }
}

/**
 * Read-only connections (#139): which statements the runner refuses to send, again after the
 * app (SQLReadOnly.swift holds the same rules). Refused: statements that would make the
 * session writable again (SET … TRANSACTION READ WRITE, SET transaction_read_only,
 * SET default_transaction_read_only, SET SESSION CHARACTERISTICS, BEGIN/START TRANSACTION
 * … READ WRITE, RESET ALL, DISCARD ALL, PRAGMA query_only, set_config()), anything that
 * doesn't start with a reading keyword (or plain transaction control), reads with a writing
 * keyword inside (a writable CTE, SELECT … INTO, FOR UPDATE, EXPLAIN ANALYZE of a write),
 * and a second statement after a `;`. The statement is read as each database could read it:
 * with and without backslash escapes, MySQL's executable comments opened, and `#` as a
 * comment (MySQL) or an operator (PostgreSQL, SQLite).
 */
final class SqlReadOnly
{
    private const READING = ['SELECT', 'SHOW', 'DESCRIBE', 'DESC', 'EXPLAIN', 'VALUES', 'TABLE', 'WITH', 'PRAGMA'];
    private const TRANSACTION = ['BEGIN', 'START', 'COMMIT', 'ROLLBACK', 'END', 'SAVEPOINT', 'RELEASE', 'ABORT'];
    private const SETTINGS = ['TRANSACTION_READ_ONLY', 'TX_READ_ONLY', 'DEFAULT_TRANSACTION_READ_ONLY', 'QUERY_ONLY'];
    private const EMBEDDED = ['INSERT', 'UPDATE', 'DELETE', 'MERGE', 'INTO', 'CREATE', 'DROP', 'ALTER', 'TRUNCATE'];
    private const WRITING = [
        'INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'MERGE', 'UPSERT', 'CREATE', 'ALTER', 'DROP', 'TRUNCATE', 'RENAME',
        'GRANT', 'REVOKE', 'COMMENT', 'LOCK', 'UNLOCK', 'CALL', 'EXEC', 'EXECUTE', 'DO', 'COPY', 'LOAD', 'IMPORT',
        'VACUUM', 'REINDEX', 'CLUSTER', 'REFRESH', 'ATTACH', 'DETACH', 'OPTIMIZE', 'REPAIR', 'ANALYZE', 'FLUSH',
        'PURGE', 'KILL', 'HANDLER', 'SET', 'RESET', 'SECURITY', 'INSTALL', 'UNINSTALL', 'SHUTDOWN',
    ];
    private const PRAGMA_READS = ['TABLE_INFO', 'TABLE_XINFO', 'TABLE_LIST', 'INDEX_INFO', 'INDEX_XINFO', 'INDEX_LIST', 'FOREIGN_KEY_LIST', 'FOREIGN_KEY_CHECK', 'INTEGRITY_CHECK', 'QUICK_CHECK'];

    /**
     * Why `$sql` isn't sent on a read-only connection ("can change data or the schema
     * (INSERT)"), or null when it may run.
     */
    public static function refusal(string $sql, ?string $driver): ?string
    {
        foreach (self::readings($sql, $driver) as [$text, $escapes, $hashComments]) {
            $refusal = self::check(self::tokens($text, $escapes, $hashComments));
            if ($refusal !== null) {
                return $refusal;
            }
        }

        return null;
    }

    /**
     * Init statements (#140): why a saved connection's init statement can't run, or null.
     * Every connection refuses an empty one, several statements in one, and transaction
     * control (an init statement can't leave a transaction open, nor commit one). A read-only
     * connection also refuses what `refusal()` refuses, except session settings (`SET
     * search_path …`, `SET time_zone …`) that leave it read-only and change nothing
     * server-wide; the runner sends them after the read-only setting and checks the setting
     * again afterwards.
     */
    public static function initRefusal(string $sql, ?string $driver, bool $readOnly): ?string
    {
        foreach (self::readings($sql, $driver) as [$text, $escapes, $hashComments]) {
            $refusal = self::checkInit(self::tokens($text, $escapes, $hashComments), $readOnly);
            if ($refusal !== null) {
                return $refusal;
            }
        }

        return null;
    }

    /**
     * The ways `$driver` could read `$sql`: [text, backslash escapes, `#` comments].
     *
     * @return array<int, array{0: string, 1: bool, 2: bool}>
     */
    private static function readings(string $sql, ?string $driver): array
    {
        $backslash = strpos($sql, '\\') !== false;
        $readings = [];
        if ($driver === null || $driver === 'mysql') {
            $readings[] = [$sql, false, true];
            if ($backslash) {
                $readings[] = [$sql, true, true];
            }
            if (preg_match('~/\*M?!~', $sql) === 1) {
                $opened = (string) preg_replace('~/\*M?![0-9]*~', ' ', $sql);
                $readings[] = [$opened, false, true];
                $readings[] = [$opened, true, true];
            }
        }
        if ($driver !== 'mysql') {
            $readings[] = [$sql, false, false];
            if ($backslash && $driver !== 'sqlite') {
                $readings[] = [$sql, true, false];
            }
        }

        return $readings;
    }

    /** @param array<int, array{0: string, 1: string}> $tokens */
    private static function checkInit(array $tokens, bool $readOnly): ?string
    {
        if ($tokens === []) {
            return 'has no statement';
        }
        $semicolon = false;
        foreach ($tokens as [$kind]) {
            if ($kind === ';') {
                $semicolon = true;
            } elseif ($semicolon) {
                return 'holds several statements (give each its own line)';
            }
        }
        $words = [];
        foreach ($tokens as [$kind, $text]) {
            if ($kind === 'w') {
                $words[] = ltrim($text, '@');
            }
        }
        $first = $words[0] ?? '';
        $second = $words[1] ?? '';
        if (in_array($first, self::TRANSACTION, true) && ($first !== 'START' || $second === 'TRANSACTION')) {
            return 'begins or ends a transaction (' . ($first === 'START' ? 'START TRANSACTION' : $first) . '), which an init statement can\'t do';
        }
        if (!$readOnly) {
            return null;
        }
        if ($first === 'SET') {
            foreach ($words as $word) {
                if (in_array($word, ['GLOBAL', 'PERSIST', 'PERSIST_ONLY', 'PASSWORD'], true)) {
                    return 'changes a server-wide setting or an account (SET … ' . $word . ')';
                }
            }
            if ($second === 'DEFAULT' && ($words[2] ?? '') === 'ROLE') {
                return 'changes an account (SET DEFAULT ROLE)';
            }
        }

        return self::check($tokens, true);
    }

    /**
     * @param array<int, array{0: string, 1: string}> $tokens
     * @param bool $sessionSettings Allow SET of settings that keep the session read-only (init statements).
     */
    private static function check(array $tokens, bool $sessionSettings = false): ?string
    {
        if ($tokens === []) {
            return null;
        }
        $semicolon = false;
        foreach ($tokens as [$kind]) {
            if ($kind === ';') {
                $semicolon = true;
            } elseif ($semicolon) {
                return 'holds several statements, and Runlet sends one at a time';
            }
        }
        // Words, and names that include quoted ones (`transaction_read_only`) for the settings.
        $words = [];
        $names = [];
        foreach ($tokens as [$kind, $text]) {
            if ($kind === 'w') {
                $words[] = $text;
                $names[] = ltrim($text, '@');
            } elseif ($kind === 'q') {
                $names[] = $text;
            }
        }
        if ($words === []) {
            return 'is one Runlet can\'t classify, so it can\'t tell whether it changes data';
        }
        $first = $words[0];
        $second = $words[1] ?? '';
        $change = static function (string $phrase): string {
            return 'would make the read-only session writable again (' . $phrase . ')';
        };
        if (in_array('SET_CONFIG', $names, true)) {
            return $change('set_config()');
        }
        foreach ($names as $name) {
            if (in_array($name, self::SETTINGS, true) && in_array($first, ['SET', 'RESET', 'PRAGMA', 'ALTER'], true)) {
                return $change($first . ' ' . strtolower($name));
            }
        }
        $readWrite = false;
        for ($index = 0; $index + 1 < count($tokens); $index++) {
            if ($tokens[$index][0] === 'w' && $tokens[$index][1] === 'READ' && $tokens[$index + 1][0] === 'w' && $tokens[$index + 1][1] === 'WRITE') {
                $readWrite = true;
            }
        }
        if ($first === 'SET' && (in_array('CHARACTERISTICS', $names, true) || $readWrite)) {
            return $change('SET … TRANSACTION READ WRITE');
        }
        if (in_array($first, ['BEGIN', 'START'], true) && $readWrite) {
            return $change($first . ' … READ WRITE');
        }
        if (in_array($first, ['RESET', 'DISCARD'], true) && $second === 'ALL') {
            return $change($first . ' ALL');
        }
        if (in_array($first, self::TRANSACTION, true) && ($first !== 'START' || $second === 'TRANSACTION')) {
            return null;
        }
        if ($first === 'SET' && $sessionSettings) {
            return null;
        }
        if (in_array($first, ['SET', 'RESET'], true)) {
            return 'changes the session\'s settings (' . $first . '), which could make it writable again';
        }
        if (in_array($first, self::WRITING, true)) {
            return 'can change data or the schema (' . $first . ')';
        }
        if (!in_array($first, self::READING, true)) {
            return 'starts with ' . $first . ', and Runlet can\'t tell whether it changes data';
        }
        if ($first === 'PRAGMA') {
            foreach ($tokens as $index => [$kind, $text]) {
                if ($kind === 'p' && $text === '=') {
                    return 'can change data or the schema (PRAGMA … =)';
                }
                if ($kind === 'p' && $text === '(') {
                    $name = '';
                    for ($before = $index - 1; $before >= 0; $before--) {
                        if ($tokens[$before][0] === 'w') {
                            $name = $tokens[$before][1];
                            break;
                        }
                    }

                    return in_array($name, self::PRAGMA_READS, true) ? null : 'can change data or the schema (PRAGMA … (…))';
                }
            }

            return null;
        }
        if ($first === 'EXPLAIN') {
            if (!in_array('ANALYZE', array_slice($words, 1, 3), true)) {
                return null;
            }
            foreach (array_slice($words, 1) as $name) {
                if (in_array($name, self::EMBEDDED, true) && $name !== 'INTO') {
                    return 'can change data or the schema (EXPLAIN ANALYZE … ' . $name . ')';
                }
            }

            return null;
        }
        foreach (array_slice($words, 1) as $position => $name) {
            if (in_array($name, self::EMBEDDED, true)) {
                $previous = $words[$position] ?? '';
                if ($name === 'UPDATE' && in_array($previous, ['FOR', 'KEY'], true)) {
                    return 'can change data or the schema (FOR UPDATE, which locks rows)';
                }

                return 'can change data or the schema (' . ($name === 'INTO' ? $first . ' … INTO' : $name) . ')';
            }
        }

        return null;
    }

    /**
     * The statement's tokens without comments: [kind, text], kind w (word, upper case), q
     * (quoted name, upper case), s (string), n (number), p (punctuation), or ;.
     *
     * @return array<int, array{0: string, 1: string}>
     */
    private static function tokens(string $sql, bool $escapes, bool $hashComments): array
    {
        $tokens = [];
        $length = strlen($sql);
        $i = 0;
        while ($i < $length) {
            $c = $sql[$i];
            $next = $i + 1 < $length ? $sql[$i + 1] : '';
            if (strpos(" \t\r\n\f", $c) !== false) {
                $i++;
                continue;
            }
            if (($c === '-' && $next === '-') || ($hashComments && $c === '#' && $next !== '>' && $next !== '-')) {
                $end = strpos($sql, "\n", $i);
                $i = $end === false ? $length : $end;
                continue;
            }
            if ($c === '/' && $next === '*') {
                $end = strpos($sql, '*/', $i + 2);
                $i = $end === false ? $length : $end + 2;
                continue;
            }
            if ($c === "'" || $c === '"' || $c === '`') {
                $j = $i + 1;
                while ($j < $length) {
                    if ($escapes && $c === "'" && $sql[$j] === '\\') {
                        $j += 2;
                        continue;
                    }
                    if ($sql[$j] === $c) {
                        if ($j + 1 < $length && $sql[$j + 1] === $c) {
                            $j += 2;
                            continue;
                        }
                        break;
                    }
                    $j++;
                }
                $tokens[] = [$c === "'" ? 's' : 'q', strtoupper(substr($sql, $i + 1, max(0, min($j, $length) - $i - 1)))];
                $i = $j + 1;
                continue;
            }
            if ($c === '$' && preg_match('/\G\$([A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*)?\$/', $sql, $match, 0, $i) === 1) {
                // A dollar-quoted body: $$…$$ or $tag$…$tag$.
                $end = strpos($sql, $match[0], $i + strlen($match[0]));
                $i = $end === false ? $length : $end + strlen($match[0]);
                $tokens[] = ['s', ''];
                continue;
            }
            if (preg_match('/\G[0-9]+[0-9A-Za-z.]*|\G\.[0-9][0-9A-Za-z.]*/', $sql, $match, 0, $i) === 1) {
                $tokens[] = ['n', $match[0]];
                $i += strlen($match[0]);
                continue;
            }
            if (preg_match('/\G[A-Za-z_\x80-\xff@][A-Za-z0-9_$@\x80-\xff]*/', $sql, $match, 0, $i) === 1) {
                $tokens[] = ['w', strtoupper($match[0])];
                $i += strlen($match[0]);
                continue;
            }
            $tokens[] = [$c === ';' ? ';' : 'p', $c];
            $i++;
        }

        return $tokens;
    }
}
