<?php

declare(strict_types=1);

/*
 * Redis tabs (#190): runs a Redis tab's commands and reports each reply as a `redis` event;
 * the key browser (SCAN pages, a key's value and memory) and the server panel (INFO, CLIENT
 * LIST, CLIENT KILL). The app generates the snippet that calls RedisTab (RedisTabRun in
 * RunletCore): each command's arguments are PHP string literals, never credentials.
 *
 * Where the connection comes from:
 *  0. a saved Redis connection (#138's `sqlConnection` with driver `redis`): Runner::main()
 *     hands it to RedisConnect::configure() and drops it from the request; the run boots no
 *     project code. Runlet's own RESP client (RedisClient) opens it with stream_socket_client
 *     (tcp://, tls://, unix://), sends AUTH (password or ACL user) and SELECT, and speaks
 *     RESP2 (it reads RESP3 types too, for HELLO 3). No PHP extension is needed, so it works on
 *     every target and from this Mac;
 *  1. the booted driver's redisConnection(): a project driver's own, or Laravel's
 *     Redis::connection($name) (phpredis through rawCommand(), Predis through executeRaw()).
 *     The application's own connections need no credentials from Runlet;
 *  2. otherwise a RedisUnavailable error that says so.
 *
 * Safety: streaming commands (SUBSCRIBE, MONITOR, …) are refused. A read-only saved
 * connection refuses every command that isn't a read (RedisCommands, the app's table again)
 * and asks the server's COMMAND INFO too, before anything is sent. Passwords: the saved
 * connection's is never a function argument and is forgotten once the connection is open;
 * typed AUTH passwords are echoed as ••• and scrubbed from every event (Channel::addSecret).
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

/** The project has no Redis connection Redis tabs can use. */
final class RedisUnavailable extends \RuntimeException
{
}

/** The connection could not be opened or broke (a refused AUTH, a closed socket, …). */
final class RedisConnectionFailed extends \RuntimeException
{
}

/** Runlet refused to send a command (read-only, streaming). Nothing was sent. */
final class RedisRefused extends \RuntimeException
{
}

/** A command got an error reply; Run All stops there. */
final class RedisCommandFailed extends \RuntimeException
{
}

/**
 * Which commands read (#190): the same lists as RedisCommands.swift (RedisCommandTableTests
 * compares them). Anything that isn't a read, connection state, or transaction control may
 * write, and a read-only connection refuses it.
 */
final class RedisCommands
{
    public const CONTAINERS = ['ACL', 'CLIENT', 'CLUSTER', 'COMMAND', 'CONFIG', 'FUNCTION', 'LATENCY', 'MEMORY', 'MODULE', 'OBJECT', 'PUBSUB', 'SCRIPT', 'SLOWLOG', 'XGROUP', 'XINFO'];

    public const READS = [
        'GET', 'MGET', 'GETRANGE', 'SUBSTR', 'STRLEN', 'EXISTS', 'TYPE', 'TTL', 'PTTL', 'EXPIRETIME', 'PEXPIRETIME', 'DBSIZE',
        'RANDOMKEY', 'SCAN', 'KEYS', 'DUMP', 'TOUCH', 'LCS', 'SORT_RO', 'GETBIT', 'BITCOUNT', 'BITPOS', 'BITFIELD_RO',
        'OBJECT|ENCODING', 'OBJECT|FREQ', 'OBJECT|IDLETIME', 'OBJECT|REFCOUNT', 'OBJECT|HELP',
        'HGET', 'HMGET', 'HGETALL', 'HKEYS', 'HVALS', 'HLEN', 'HEXISTS', 'HSTRLEN', 'HSCAN', 'HRANDFIELD',
        'HTTL', 'HPTTL', 'HEXPIRETIME', 'HPEXPIRETIME',
        'LINDEX', 'LLEN', 'LRANGE', 'LPOS',
        'SCARD', 'SISMEMBER', 'SMISMEMBER', 'SMEMBERS', 'SRANDMEMBER', 'SSCAN', 'SINTER', 'SINTERCARD', 'SUNION', 'SDIFF',
        'ZCARD', 'ZCOUNT', 'ZLEXCOUNT', 'ZRANGE', 'ZRANGEBYSCORE', 'ZRANGEBYLEX', 'ZREVRANGE', 'ZREVRANGEBYSCORE',
        'ZREVRANGEBYLEX', 'ZRANK', 'ZREVRANK', 'ZSCORE', 'ZMSCORE', 'ZSCAN', 'ZRANDMEMBER', 'ZINTER', 'ZINTERCARD', 'ZUNION', 'ZDIFF',
        'XRANGE', 'XREVRANGE', 'XLEN', 'XREAD', 'XPENDING', 'XINFO|STREAM', 'XINFO|GROUPS', 'XINFO|CONSUMERS', 'XINFO|HELP',
        'XGROUP|HELP',
        'GEOPOS', 'GEODIST', 'GEOHASH', 'GEORADIUS_RO', 'GEORADIUSBYMEMBER_RO', 'GEOSEARCH', 'PFCOUNT',
        'EVAL_RO', 'EVALSHA_RO', 'FCALL_RO', 'SCRIPT|EXISTS', 'SCRIPT|HELP', 'FUNCTION|LIST', 'FUNCTION|DUMP', 'FUNCTION|STATS',
        'FUNCTION|HELP',
        'INFO', 'TIME', 'LASTSAVE', 'ROLE', 'LOLWUT', 'MEMORY|USAGE', 'MEMORY|STATS', 'MEMORY|DOCTOR', 'MEMORY|MALLOC-STATS',
        'MEMORY|HELP', 'LATENCY|LATEST', 'LATENCY|HISTORY', 'LATENCY|DOCTOR', 'LATENCY|GRAPH', 'LATENCY|HISTOGRAM',
        'LATENCY|HELP', 'SLOWLOG|GET', 'SLOWLOG|LEN', 'SLOWLOG|HELP', 'CONFIG|GET', 'CONFIG|HELP', 'CLIENT|LIST',
        'CLIENT|INFO', 'CLIENT|ID', 'CLIENT|GETNAME', 'CLIENT|GETREDIR', 'CLIENT|TRACKINGINFO', 'CLIENT|HELP', 'COMMAND',
        'COMMAND|COUNT', 'COMMAND|DOCS', 'COMMAND|GETKEYS', 'COMMAND|GETKEYSANDFLAGS', 'COMMAND|INFO', 'COMMAND|LIST',
        'COMMAND|HELP', 'MODULE|LIST', 'MODULE|HELP', 'ACL|WHOAMI', 'ACL|LIST', 'ACL|USERS', 'ACL|GETUSER', 'ACL|CAT',
        'ACL|LOG', 'ACL|GENPASS', 'ACL|DRYRUN', 'ACL|HELP', 'PUBSUB|CHANNELS', 'PUBSUB|NUMSUB', 'PUBSUB|NUMPAT',
        'PUBSUB|SHARDCHANNELS', 'PUBSUB|SHARDNUMSUB', 'PUBSUB|HELP', 'CLUSTER|INFO', 'CLUSTER|NODES', 'CLUSTER|SLOTS',
        'CLUSTER|SHARDS', 'CLUSTER|MYID', 'CLUSTER|MYSHARDID', 'CLUSTER|KEYSLOT', 'CLUSTER|COUNTKEYSINSLOT',
        'CLUSTER|GETKEYSINSLOT', 'CLUSTER|LINKS', 'CLUSTER|HELP',
    ];

    public const CONNECTION = [
        'AUTH', 'HELLO', 'PING', 'ECHO', 'SELECT', 'QUIT', 'RESET', 'READONLY', 'READWRITE', 'ASKING', 'WAIT', 'WAITAOF',
        'CLIENT|SETNAME', 'CLIENT|SETINFO', 'CLIENT|TRACKING', 'CLIENT|CACHING', 'CLIENT|NO-EVICT', 'CLIENT|NO-TOUCH',
    ];

    public const TRANSACTION = ['MULTI', 'EXEC', 'DISCARD', 'WATCH', 'UNWATCH'];

    public const STREAMING = [
        'SUBSCRIBE', 'PSUBSCRIBE', 'SSUBSCRIBE', 'UNSUBSCRIBE', 'PUNSUBSCRIBE', 'SUNSUBSCRIBE', 'MONITOR', 'SYNC', 'PSYNC',
        'REPLCONF', 'CLIENT|REPLY',
    ];

    /** @param string[] $argv */
    public static function key(array $argv): string
    {
        $first = strtoupper((string) ($argv[0] ?? ''));
        if (in_array($first, self::CONTAINERS, true) && count($argv) > 1) {
            return $first . '|' . strtoupper((string) $argv[1]);
        }

        return $first;
    }

    /** "CONFIG GET" */
    public static function name(array $argv): string
    {
        return str_replace('|', ' ', self::key($argv));
    }

    /**
     * Why a read-only connection refuses `$argv` ("can change data or the server (SET)"), or null.
     *
     * @param string[] $argv
     */
    public static function readOnlyRefusal(array $argv): ?string
    {
        $key = self::key($argv);
        $name = self::name($argv);
        if (in_array($key, self::STREAMING, true)) {
            return 'streams replies (' . $name . '), which Redis tabs don\'t read yet';
        }
        if ($key === 'ACL|LOG' && in_array('RESET', array_map('strtoupper', array_slice($argv, 2)), true)) {
            return 'can change data or the server (ACL LOG RESET)';
        }
        if (in_array($key, self::READS, true) || in_array($key, self::CONNECTION, true) || in_array($key, self::TRANSACTION, true)) {
            return null;
        }
        $known = in_array(strtoupper((string) ($argv[0] ?? '')), self::CONTAINERS, true) || self::isWrite($key);

        return $known ? 'can change data or the server (' . $name . ')' : 'is a command Runlet doesn\'t know (' . $name . '), so it can\'t tell whether it writes';
    }

    /** Whether the key names a command Runlet knows writes (the rest of the table is the app's). */
    private static function isWrite(string $key): bool
    {
        return preg_match('/^(SET|MSET|GETSET|GETDEL|GETEX|APPEND|INCR|DECR|DEL|UNLINK|EXPIRE|PEXPIRE|PERSIST|RENAME|MOVE|COPY|RESTORE|SORT|BIT|H(SET|MSET|DEL|INCR|EXPIRE|PEXPIRE|PERSIST)|[LR]PUSH|[LR]POP|LINSERT|LSET|LREM|LTRIM|LMOVE|LMPOP|B[LRZ]|S(ADD|REM|POP|MOVE)|S(INTER|UNION|DIFF)STORE|Z(ADD|INCRBY|REM|POP|MPOP|RANGESTORE|INTERSTORE|UNIONSTORE|DIFFSTORE)|X(ADD|DEL|TRIM|ACK|CLAIM|AUTOCLAIM|SETID|READGROUP|GROUP)|GEO(ADD|RADIUS|SEARCHSTORE)|PF(ADD|MERGE|DEBUG|SELFTEST)|EVAL|FCALL|PUBLISH|SPUBLISH|FLUSH|SWAPDB|SHUTDOWN|DEBUG|MIGRATE|REPLICAOF|SLAVEOF|SAVE|BGSAVE|BGREWRITEAOF|FAILOVER)/', $key) === 1;
    }

    /** Why a Redis tab never sends `$argv` on any connection, or null. */
    public static function refusal(array $argv): ?string
    {
        $key = self::key($argv);
        if (!in_array($key, self::STREAMING, true)) {
            return null;
        }
        $name = self::name($argv);
        if ($key === 'CLIENT|REPLY') {
            return 'CLIENT REPLY turns replies off, and Runlet reads one reply per command. Nothing ran.';
        }

        return $name . ' streams messages until the connection closes, and Redis tabs read one reply per command (streaming is a later feature). Use redis-cli for ' . $name . '. Nothing ran.';
    }
}

/**
 * Builds reply trees with Runlet's caps: strings are shortened (a top-level string to 512 KiB,
 * others to 8 KiB), aggregates keep `$cap` elements and count the rest, and the whole reply
 * keeps at most 8 MiB of strings. Shared by the RESP client and the application adapters.
 */
final class RedisReplyBudget
{
    public const TOP_STRING_BYTES = 524288;
    public const STRING_BYTES = 8192;
    public const TOTAL_BYTES = 8388608;

    /** @var int */
    public $left = self::TOTAL_BYTES;
    /** @var int */
    public $used = 0;

    /**
     * A string node: UTF-8 text (shortened, with `o` the bytes left out), or binary (`x`).
     *
     * @return array<string, mixed>
     */
    public function text(string $kept, int $total, bool $top): array
    {
        $limit = min($top ? self::TOP_STRING_BYTES : self::STRING_BYTES, max(0, $this->left));
        if (strlen($kept) > $limit) {
            $kept = substr($kept, 0, $limit);
        }
        if (preg_match('//u', $kept) !== 1) {
            // A cut in the middle of a character, or bytes that aren't UTF-8.
            $trimmed = $kept;
            for ($i = 0; $i < 3 && $trimmed !== '' && preg_match('//u', $trimmed) !== 1; $i++) {
                $trimmed = substr($trimmed, 0, -1);
            }
            if (preg_match('//u', $trimmed) !== 1 || ($trimmed === '' && $kept !== '')) {
                $this->spend(80);

                return ['t' => 'x', 'n' => $total, 'h' => strtoupper(bin2hex(substr($kept, 0, 32)))];
            }
            $kept = $trimmed;
        }
        $this->spend(strlen($kept));

        return $total > strlen($kept) ? ['t' => 's', 'v' => $kept, 'o' => $total - strlen($kept)] : ['t' => 's', 'v' => $kept];
    }

    public function spend(int $bytes): void
    {
        $this->left -= $bytes;
        $this->used += $bytes;
    }

    public function exhausted(): bool
    {
        return $this->left <= 0;
    }
}

/**
 * Runlet's RESP client (#190): one connection, commands sent as RESP arrays, replies read
 * with caps. It reads RESP2 and RESP3 types. Blocking commands wait until they're answered;
 * Stop ends the process, which closes the socket, and Redis unblocks the client.
 */
final class RedisClient
{
    /** @var resource */
    private $stream;
    /** @var string */
    private $buffer = '';

    /** @param resource $stream */
    public function __construct($stream)
    {
        $this->stream = $stream;
    }

    /** @return resource */
    public function stream()
    {
        return $this->stream;
    }

    /**
     * Sends `$argv` and reads its reply.
     *
     * @param string[] $argv
     * @return array<string, mixed>
     */
    public function command(array $argv, int $cap = 1000, ?RedisReplyBudget $budget = null): array
    {
        $this->send($argv);

        return $this->read($cap, $budget ?? new RedisReplyBudget());
    }

    /** @param string[] $argv */
    public function send(array $argv): void
    {
        $out = '*' . count($argv) . "\r\n";
        foreach ($argv as $argument) {
            $argument = (string) $argument;
            $out .= '$' . strlen($argument) . "\r\n" . $argument . "\r\n";
        }
        $length = strlen($out);
        $written = 0;
        while ($written < $length) {
            $result = @fwrite($this->stream, substr($out, $written, 65536));
            if ($result === false || $result === 0) {
                throw new RedisConnectionFailed('Runlet could not send the command: the connection to Redis closed.');
            }
            $written += $result;
        }
    }

    /**
     * Reads one reply.
     *
     * @return array<string, mixed>
     */
    public function read(int $cap, RedisReplyBudget $budget, int $depth = 0): array
    {
        $line = $this->line();
        $type = $line === '' ? '' : $line[0];
        $rest = (string) substr($line, 1);
        switch ($type) {
            case '+':
                return ['t' => '+', 'v' => $this->scrubbed($rest)];
            case '-':
                return ['t' => '-', 'v' => $this->scrubbed($rest)];
            case ':':
                return ['t' => 'i', 'v' => (int) $rest];
            case ',':
                return ['t' => 'd', 'v' => $rest];
            case '#':
                return ['t' => 'b', 'v' => $rest === 't'];
            case '_':
                return ['t' => 'n'];
            case '(':
                return ['t' => 's', 'v' => $rest];
            case '$':
            case '=':
            case '!':
                $length = (int) $rest;
                if ($length < 0) {
                    return ['t' => 'n'];
                }
                $keep = $depth === 0 ? RedisReplyBudget::TOP_STRING_BYTES : RedisReplyBudget::STRING_BYTES;
                $kept = $this->bulk($length, min($keep, max(0, $budget->left)));
                if ($type === '!') {
                    return ['t' => '-', 'v' => $this->scrubbed($kept)];
                }
                if ($type === '=' && strlen($kept) >= 4 && $kept[3] === ':') {
                    // A verbatim string: "txt:" or "mkd:" first.
                    $kept = substr($kept, 4);
                    $length -= 4;
                }

                return $budget->text($kept, $length, $depth === 0);
            case '*':
            case '~':
            case '>':
            case '%':
            case '|':
                $count = (int) $rest;
                if ($count < 0) {
                    return ['t' => 'n'];
                }
                if ($type === '|') {
                    // RESP3 attributes come before the reply they describe: skipped.
                    for ($i = 0; $i < $count * 2; $i++) {
                        $this->skip();
                    }

                    return $this->read($cap, $budget, $depth);
                }
                $pairs = $type === '%';
                $elements = $pairs ? $count * 2 : $count;
                $items = [];
                $omitted = 0;
                $keep = $pairs ? max(2, $cap - $cap % 2) : $cap;
                for ($i = 0; $i < $elements; $i++) {
                    if ($i >= $keep || $budget->exhausted()) {
                        $this->skip();
                        $omitted++;
                        continue;
                    }
                    $items[] = $this->read($cap, $budget, $depth + 1);
                }
                if ($pairs) {
                    $grouped = [];
                    for ($i = 0; $i + 1 < count($items); $i += 2) {
                        $grouped[] = [$items[$i], $items[$i + 1]];
                    }
                    $node = ['t' => '%', 'v' => $grouped];
                    if ($omitted > 0) {
                        $node['o'] = intdiv($omitted + 1, 2);
                    }

                    return $node;
                }
                $node = ['t' => $type === '~' ? '~' : '*', 'v' => $items];
                if ($omitted > 0) {
                    $node['o'] = $omitted;
                }

                return $node;
            default:
                throw new RedisConnectionFailed('Runlet could not read the reply (it starts with ' . json_encode(substr($line, 0, 20)) . '). Is this a Redis server?');
        }
    }

    /** Reads and drops one reply (an element past the cap). */
    private function skip(): void
    {
        $line = $this->line();
        $type = $line === '' ? '' : $line[0];
        $count = (int) substr($line, 1);
        switch ($type) {
            case '$':
            case '=':
            case '!':
                if ($count >= 0) {
                    $this->bulk($count, 0);
                }

                return;
            case '*':
            case '~':
            case '>':
            case '%':
            case '|':
                $elements = $type === '%' || $type === '|' ? $count * 2 : $count;
                for ($i = 0; $i < $elements; $i++) {
                    $this->skip();
                }
                if ($type === '|') {
                    $this->skip();
                }

                return;
            default:
                return;
        }
    }

    /** A status or error line, without the saved connection's password. */
    private function scrubbed(string $text): string
    {
        return Channel::scrub($text);
    }

    /** One line, without its CRLF. */
    private function line(): string
    {
        while (($end = strpos($this->buffer, "\r\n")) === false) {
            $this->fill();
        }
        $line = substr($this->buffer, 0, $end);
        $this->buffer = (string) substr($this->buffer, $end + 2);

        return $line;
    }

    /** A bulk string of `$length` bytes and its CRLF: the first `$keep` bytes, the rest dropped. */
    private function bulk(int $length, int $keep): string
    {
        $needed = $length + 2;
        $kept = '';
        while ($needed > 0) {
            if ($this->buffer === '') {
                $this->fill();
            }
            $take = min($needed, strlen($this->buffer));
            $chunk = substr($this->buffer, 0, $take);
            $this->buffer = (string) substr($this->buffer, $take);
            $room = $keep - strlen($kept);
            if ($room > 0) {
                $kept .= substr($chunk, 0, $room);
            }
            $needed -= $take;
        }
        // The CRLF may have been kept with the bytes.
        return strlen($kept) > $length ? substr($kept, 0, $length) : $kept;
    }

    private function fill(): void
    {
        $chunk = @fread($this->stream, 65536);
        if ($chunk === false || $chunk === '') {
            $meta = @stream_get_meta_data($this->stream);
            if (is_array($meta) && !empty($meta['timed_out'])) {
                throw new RedisConnectionFailed('Redis didn\'t answer in time.');
            }
            if (!is_resource($this->stream) || feof($this->stream)) {
                throw new RedisConnectionFailed('The connection to Redis closed before the reply was complete.');
            }
            if ($chunk === false) {
                throw new RedisConnectionFailed('Runlet could not read from the connection to Redis.');
            }

            return;
        }
        $this->buffer .= $chunk;
    }

    public function close(): void
    {
        if (is_resource($this->stream)) {
            @fclose($this->stream);
        }
    }
}

/**
 * A saved Redis connection (#190): its definition from the runner request (the password is
 * forgotten once the connection is open), and opening it with RedisClient.
 */
final class RedisConnect
{
    private const TLS_MODES = ['', 'disable', 'require', 'verify-full'];

    /** @var array<string, mixed>|null */
    private static $definition;
    /** @var string|null */
    private static $password;
    /** @var RedisClient|null */
    private static $client;
    /** @var float|null */
    private static $connectMs;
    /** @var array<string, mixed> */
    private static $crypto = [];

    /** @param array<string, mixed> $connection */
    public static function configure(array $connection): void
    {
        $password = isset($connection['password']) && is_string($connection['password']) ? $connection['password'] : null;
        unset($connection['password']);
        $tls = is_array($connection['tls'] ?? null) ? $connection['tls'] : [];
        $tunnel = is_array($connection['tunnel'] ?? null) ? $connection['tunnel'] : [];
        self::$definition = [
            'id' => (string) ($connection['id'] ?? ''),
            'name' => (string) ($connection['name'] ?? ''),
            'host' => (string) ($connection['host'] ?? ''),
            'port' => isset($connection['port']) ? (int) $connection['port'] : 6379,
            'database' => (string) ($connection['database'] ?? ''),
            'user' => (string) ($connection['user'] ?? ''),
            'timeout' => max(1, min(300, (int) ($connection['timeout'] ?? 10))),
            'summary' => (string) ($connection['summary'] ?? ''),
            'readOnly' => ($connection['readOnly'] ?? false) === true,
            'socket' => (string) ($connection['socket'] ?? ''),
            'tls' => [
                'mode' => (string) ($tls['mode'] ?? ''),
                'ca' => (string) ($tls['ca'] ?? ''),
                'cert' => (string) ($tls['cert'] ?? ''),
                'key' => (string) ($tls['key'] ?? ''),
            ],
            'place' => ($connection['place'] ?? '') === 'mac' ? 'mac' : 'target',
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

    public static function name(): string
    {
        return (string) (self::$definition['name'] ?? '');
    }

    public static function isReadOnly(): bool
    {
        return (self::$definition['readOnly'] ?? false) === true;
    }

    /** The database the connection selects (0 when it names none). */
    public static function database(): int
    {
        return (int) (self::$definition['database'] ?? 0);
    }

    /** `saved connection "Cache" (redis, 127.0.0.1:6379/0)`, read-only noted. */
    public static function origin(): string
    {
        $summary = (string) (self::$definition['summary'] ?? '');

        return 'saved connection "' . self::name() . '"' . ($summary === '' ? '' : ' (' . $summary . ')') . (self::isReadOnly() ? ', read-only' : '');
    }

    private static function here(): string
    {
        return (self::$definition['place'] ?? '') === 'mac' ? 'this Mac' : 'this target';
    }

    /** The open connection; opens it on first use. */
    public static function client(): RedisClient
    {
        if (self::$client === null) {
            $started = hrtime(true);
            try {
                self::$client = self::connect();
            } finally {
                self::$password = null;
            }
            self::$connectMs = round((hrtime(true) - $started) / 1e6, 3);
        }

        return self::$client;
    }

    /**
     * Opens the connection: the address and stream context, AUTH, SELECT. Takes no arguments,
     * so the password is never in a stack frame; errors carry their message only.
     */
    private static function connect(): RedisClient
    {
        $definition = self::$definition;
        if ($definition === null) {
            throw new RedisConnectionFailed('No saved connection was sent with this run.');
        }
        $name = '"' . $definition['name'] . '"';
        $where = $name . ' (' . $definition['summary'] . ')';
        $tls = $definition['tls'];
        if (!in_array($tls['mode'], self::TLS_MODES, true)) {
            throw new RedisConnectionFailed('The saved connection ' . $name . ' asks for the TLS mode "' . $tls['mode'] . '", which Runlet\'s Redis client can\'t express. Choose Off, Require, or Verify CA and host name.');
        }
        $secure = $tls['mode'] === 'require' || $tls['mode'] === 'verify-full';
        $host = (string) $definition['host'];
        $socket = (string) $definition['socket'];
        $tunnel = (int) $definition['tunnel']['port'];
        if ($socket !== '') {
            if ($socket[0] !== '/' || preg_match('/[\x00-\x1f]/', $socket) === 1) {
                throw new RedisConnectionFailed('The socket "' . $socket . '" must be an absolute path.');
            }
            if ($tunnel > 0) {
                throw new RedisConnectionFailed('The saved connection ' . $name . ' goes through an SSH tunnel, which forwards a host and port, not a Unix socket. Nothing ran.');
            }
            $address = 'unix://' . $socket;
        } else {
            if ($host === '' || preg_match('/^[A-Za-z0-9._:%\[\]-]+$/', $host) !== 1 || $host[0] === '-') {
                throw new RedisConnectionFailed('The saved connection\'s host "' . $host . '" isn\'t a host name or IP address.');
            }
            $connectHost = $tunnel > 0 ? '127.0.0.1' : (strpos($host, ':') !== false && $host[0] !== '[' ? '[' . $host . ']' : $host);
            $port = $tunnel > 0 ? $tunnel : (int) $definition['port'];
            $address = ($secure ? 'tls://' : 'tcp://') . $connectHost . ':' . $port;
        }
        $ssl = [];
        if ($secure) {
            $verify = $tls['mode'] === 'verify-full';
            $ssl = [
                'verify_peer' => $verify,
                'verify_peer_name' => $verify,
                'allow_self_signed' => false,
                'SNI_enabled' => true,
                // #143: through a tunnel, the certificate still names the server.
                'peer_name' => trim($host, '[]'),
                'capture_session_meta' => true,
            ];
            foreach (['ca' => 'cafile', 'cert' => 'local_cert', 'key' => 'local_pk'] as $field => $option) {
                if ($tls[$field] !== '') {
                    $path = $tls[$field];
                    if ($path[0] !== '/' || !is_readable($path)) {
                        throw new RedisConnectionFailed('The TLS file ' . $path . ' doesn\'t exist on ' . self::here() . ', or its PHP can\'t read it. Nothing ran.');
                    }
                    $ssl[$option] = $path;
                }
            }
            if ($socket !== '') {
                throw new RedisConnectionFailed('Runlet\'s Redis client connects to a Unix socket without TLS. Turn TLS off for a socket connection.');
            }
            if (!extension_loaded('openssl')) {
                throw new RedisConnectionFailed((self::here() === 'this Mac' ? 'This Mac\'s PHP ' : 'This target\'s PHP ') . PHP_VERSION . ' has no openssl extension, so it can\'t open a TLS connection.');
            }
        }
        $context = stream_context_create(['ssl' => $ssl, 'socket' => ['tcp_nodelay' => true]]);
        $warnings = [];
        set_error_handler(static function (int $severity, string $message) use (&$warnings): bool {
            $warnings[] = $message;

            return true;
        });
        $errno = 0;
        $errstr = '';
        try {
            $stream = stream_socket_client($address, $errno, $errstr, (float) $definition['timeout'], STREAM_CLIENT_CONNECT, $context);
        } finally {
            restore_error_handler();
        }
        if ($stream === false) {
            $hint = $tunnel > 0
                ? ' The SSH server of "' . $definition['tunnel']['via'] . '" connects to Redis for the tunnel, so the host and port are as that server sees them; check it can reach them.'
                : '';
            $detail = trim($errstr . ($warnings === [] ? '' : ' ' . implode(' ', array_unique($warnings))));
            throw new RedisConnectionFailed(Channel::scrub('Runlet could not open the saved connection ' . $where . ': ' . ($detail === '' ? 'error ' . $errno : $detail) . $hint));
        }
        stream_set_timeout($stream, 31536000);
        if ($secure) {
            $meta = stream_get_meta_data($stream);
            self::$crypto = is_array($meta['crypto'] ?? null) ? $meta['crypto'] : ['protocol' => 'TLS'];
        }
        $client = new RedisClient($stream);
        $password = self::$password;
        $user = (string) $definition['user'];
        if (($password !== null && $password !== '') || $user !== '') {
            $reply = $client->command($user !== '' ? ['AUTH', $user, (string) $password] : ['AUTH', (string) $password]);
            $password = null;
            if (($reply['t'] ?? '') === '-') {
                $client->close();
                throw new RedisConnectionFailed(Channel::scrub('Redis refused the login of the saved connection ' . $where . ': ' . (string) $reply['v']));
            }
        }
        $password = null;
        $database = self::database();
        if ($database !== 0) {
            $reply = $client->command(['SELECT', (string) $database]);
            if (($reply['t'] ?? '') === '-') {
                $client->close();
                throw new RedisConnectionFailed('Redis refused SELECT ' . $database . ' on the saved connection ' . $where . ': ' . (string) $reply['v']);
            }
        }

        return $client;
    }

    /**
     * Test Connection: PING, the server's version, the database, the ACL user, and TLS.
     *
     * @return array<string, mixed>
     */
    public static function test(): array
    {
        $client = self::client();
        $started = hrtime(true);
        $client->command(['PING']);
        $roundTrip = round((hrtime(true) - $started) / 1e6, 3);
        $version = null;
        $info = $client->command(['INFO', 'server']);
        if (($info['t'] ?? '') === 's' && preg_match('/^redis_version:(\S+)/m', (string) $info['v'], $match) === 1) {
            $version = $match[1];
        }
        $user = $client->command(['ACL', 'WHOAMI']);
        $tls = (self::$definition['tls']['mode'] ?? '') === 'require' || (self::$definition['tls']['mode'] ?? '') === 'verify-full';

        return array_filter([
            'driver' => 'redis',
            'serverVersion' => $version,
            'database' => (string) self::database(),
            // ACL WHOAMI needs a permission an ACL user may lack: the configured user then.
            'user' => ($user['t'] ?? '') === 's' ? (string) $user['v'] : ((string) (self::$definition['user'] ?? '') !== '' ? (string) self::$definition['user'] : null),
            'connectMs' => self::$connectMs,
            'roundTripMs' => $roundTrip,
            'phpVersion' => PHP_VERSION,
            'readOnly' => self::isReadOnly() ? true : null,
            'tls' => $tls,
            'tlsVersion' => $tls ? (string) (self::$crypto['protocol'] ?? 'TLS') : null,
            'tlsCipher' => $tls && isset(self::$crypto['cipher_name']) ? (string) self::$crypto['cipher_name'] : null,
        ], static function ($value): bool {
            return $value !== null;
        });
    }
}

/**
 * An application's Redis connection (#190), wrapped as `function (array $argv, int $cap,
 * RedisReplyBudget $budget): array` returning a reply tree: phpredis through rawCommand()
 * (status replies kept as text, errors from getLastError()), Predis through executeRaw(), a
 * Laravel connection through its client(), or a driver's own callable.
 */
final class RedisAppConnection
{
    /**
     * @param mixed $value
     */
    public static function executor($value, string $origin): callable
    {
        if (is_object($value) && is_a($value, 'Illuminate\Redis\Connections\Connection') && method_exists($value, 'client')) {
            $client = $value->client();
            if (is_object($client) && (is_a($client, 'Redis') || is_a($client, 'Predis\ClientInterface') || is_a($client, 'RedisCluster') || is_a($client, 'Predis\Client'))) {
                return self::executor($client, $origin);
            }
            throw new RedisConnectionFailed($origin . ' returned a ' . get_class($value) . ' whose client() is ' . (is_object($client) ? get_class($client) : gettype($client)) . ', which Runlet can\'t send raw commands through.');
        }
        if (is_object($value) && is_a($value, 'RedisCluster')) {
            throw new RedisUnavailable('This is a Redis Cluster connection (' . $origin . '). Redis tabs don\'t support Cluster yet: save a connection to one node, or use a non-cluster connection.');
        }
        if (is_object($value) && is_a($value, 'Redis')) {
            return static function (array $argv, int $cap, RedisReplyBudget $budget) use ($value): array {
                return self::phpredis($value, $argv, $cap, $budget);
            };
        }
        if (is_object($value) && (is_a($value, 'Predis\ClientInterface') || method_exists($value, 'executeRaw'))) {
            return static function (array $argv, int $cap, RedisReplyBudget $budget) use ($value): array {
                $error = false;
                $reply = $value->executeRaw(array_values($argv), $error);
                if ($error === true) {
                    return ['t' => '-', 'v' => Channel::scrub(is_object($reply) && method_exists($reply, 'getMessage') ? (string) $reply->getMessage() : (string) $reply)];
                }

                return self::convert($reply, $cap, $budget, 0);
            };
        }
        if (is_callable($value)) {
            return static function (array $argv, int $cap, RedisReplyBudget $budget) use ($value): array {
                return self::convert($value(array_values($argv)), $cap, $budget, 0);
            };
        }
        throw new RedisConnectionFailed($origin . ' returned ' . (is_object($value) ? get_class($value) : gettype($value)) . '; return a phpredis Redis, a Predis client, a Laravel Redis connection, a callable, or null.');
    }

    /**
     * @param \Redis $redis
     * @param string[] $argv
     * @return array<string, mixed>
     */
    private static function phpredis($redis, array $argv, int $cap, RedisReplyBudget $budget): array
    {
        $literal = defined('Redis::OPT_REPLY_LITERAL') ? constant('Redis::OPT_REPLY_LITERAL') : null;
        $previous = null;
        if ($literal !== null) {
            try {
                $previous = $redis->getOption($literal);
                $redis->setOption($literal, true);
            } catch (\Throwable $error) {
                $literal = null;
            }
        }
        try {
            if (method_exists($redis, 'clearLastError')) {
                $redis->clearLastError();
            }
            $reply = $redis->rawCommand(...array_values($argv));
            if ($reply === false && method_exists($redis, 'getLastError')) {
                $last = $redis->getLastError();
                if (is_string($last) && $last !== '') {
                    return ['t' => '-', 'v' => Channel::scrub($last)];
                }
            }
        } catch (\Throwable $error) {
            return ['t' => '-', 'v' => Channel::scrub($error->getMessage())];
        } finally {
            if ($literal !== null) {
                try {
                    $redis->setOption($literal, $previous);
                } catch (\Throwable $error) {
                    // Best effort.
                }
            }
        }

        return self::convert($reply, $cap, $budget, 0);
    }

    /**
     * A PHP value from a client as a reply tree.
     *
     * @param mixed $value
     * @return array<string, mixed>
     */
    public static function convert($value, int $cap, RedisReplyBudget $budget, int $depth): array
    {
        if ($value === null || $value === false) {
            return ['t' => 'n'];
        }
        if ($value === true) {
            return ['t' => '+', 'v' => 'OK'];
        }
        if (is_int($value)) {
            return ['t' => 'i', 'v' => $value];
        }
        if (is_float($value)) {
            return ['t' => 'd', 'v' => is_finite($value) ? (string) $value : ($value > 0 ? 'inf' : ($value < 0 ? '-inf' : 'nan'))];
        }
        if (is_string($value)) {
            return $budget->text($value, strlen($value), $depth === 0);
        }
        if (is_object($value)) {
            $class = get_class($value);
            if (is_a($value, 'Predis\Response\ErrorInterface') && method_exists($value, 'getMessage')) {
                return ['t' => '-', 'v' => Channel::scrub((string) $value->getMessage())];
            }
            if (is_a($value, 'Predis\Response\Status') || method_exists($value, 'getPayload')) {
                return ['t' => '+', 'v' => (string) $value->getPayload()];
            }
            if (method_exists($value, '__toString')) {
                return $budget->text((string) $value, strlen((string) $value), $depth === 0);
            }

            return ['t' => 's', 'v' => $class];
        }
        if (is_array($value)) {
            $list = array_keys($value) === range(0, count($value) - 1) || $value === [];
            $items = [];
            $omitted = 0;
            foreach ($value as $key => $item) {
                if (count($items) >= ($list ? $cap : intdiv($cap, 2)) || $budget->exhausted()) {
                    $omitted++;
                    continue;
                }
                $items[] = $list ? self::convert($item, $cap, $budget, $depth + 1) : [self::convert((string) $key, $cap, $budget, $depth + 1), self::convert($item, $cap, $budget, $depth + 1)];
            }
            $node = ['t' => $list ? '*' : '%', 'v' => $items];
            if ($omitted > 0) {
                $node['o'] = $omitted;
            }

            return $node;
        }

        return ['t' => 's', 'v' => gettype($value)];
    }
}

final class RedisTab
{
    /** Bytes of an argument echoed back with its reply. */
    private const MAX_ARGUMENT_ECHO = 300;
    private const MAX_ARGUMENTS_ECHOED = 30;

    /** @var callable|null */
    private static $executor;
    /** @var string */
    private static $origin = '';
    /** @var string[] */
    private static $names = [];

    /**
     * Runs `$commands` in order on the tab's connection (`$connection`: the application's
     * connection name, null for its default; ignored for a saved connection) and emits a
     * `redis` event for each reply. `$all` (Run All) numbers them and stops at the first
     * error; `$multi` wraps them in MULTI/EXEC, and every command's reply comes from EXEC.
     *
     * @param array<int, array{argv: string[], line: int, cap?: int, secret?: int[]}> $commands
     */
    public static function run(array $commands, ?string $connection, int $maxElements, bool $all = false, bool $multi = false): NoResult
    {
        $connection = $connection === '' ? null : $connection;
        $commands = array_values($commands);
        $count = count($commands);
        if ($count === 0) {
            throw new \InvalidArgumentException('There are no commands to run.');
        }
        foreach ($commands as $index => $command) {
            $argv = array_map('strval', array_values((array) ($command['argv'] ?? [])));
            if ($argv === []) {
                throw new \InvalidArgumentException('Command ' . ($index + 1) . ' is empty.');
            }
            foreach ((array) ($command['secret'] ?? []) as $secret) {
                if (isset($argv[(int) $secret]) && $argv[(int) $secret] !== '') {
                    Channel::addSecret($argv[(int) $secret]);
                }
            }
            $refusal = RedisCommands::refusal($argv);
            if ($refusal !== null) {
                throw new RedisRefused(($count === 1 ? '' : 'Command ' . ($index + 1) . ' of ' . $count . ' (line ' . (int) $command['line'] . '): ') . $refusal);
            }
        }
        self::refuseOnReadOnly($commands, null);
        [$execute, $origin] = self::resolve($connection);
        self::refuseOnReadOnly($commands, $execute);
        $db = RedisConnect::isConfigured() ? RedisConnect::database() : null;
        self::reportSession($execute, $connection);
        if ($multi) {
            self::runMulti($commands, $execute, $origin, $connection, $maxElements, $db);

            return NoResult::instance();
        }
        foreach ($commands as $index => $command) {
            $argv = array_map('strval', array_values($command['argv']));
            $budget = new RedisReplyBudget();
            $started = hrtime(true);
            $reply = $execute($argv, max(1, (int) ($command['cap'] ?? $maxElements)), $budget);
            $elapsed = round((hrtime(true) - $started) / 1e6, 3);
            if (($reply['t'] ?? '') === '-') {
                $where = $count === 1 || !$all ? '' : 'Command ' . ($index + 1) . ' of ' . $count . ' (line ' . (int) $command['line'] . '): ';
                $notes = [];
                if ($all && $index + 1 < $count) {
                    $notes[] = ($index + 2 === $count ? 'Command ' . $count . ' did' : 'Commands ' . ($index + 2) . '–' . $count . ' did') . ' not run.';
                    if ($index > 0) {
                        $notes[] = ($index === 1 ? 'Command 1 ran' : 'Commands 1–' . $index . ' ran') . ' and stay' . ($index === 1 ? 's' : '') . ': Redis has no rollback. Turn on "In a Transaction" (MULTI/EXEC) to queue the commands first.';
                    }
                }
                throw new RedisCommandFailed($where . (string) $reply['v'] . ($notes === [] ? '' : "\n\n" . implode(' ', $notes)));
            }
            if (strtoupper($argv[0]) === 'SELECT' && ($reply['t'] ?? '') === '+') {
                $db = (int) ($argv[1] ?? 0);
            }
            $event = self::event($argv, $command, $reply, $elapsed, $origin, $connection, $db, $maxElements, $budget);
            if ($all) {
                $event['statement'] = ['index' => $index + 1, 'count' => $count, 'line' => (int) $command['line'], 'text' => self::echoLine($argv, $command)];
            }
            if ($index === 0 && self::$names !== []) {
                $event['connections'] = self::$names;
            }
            Channel::emit('redis', $event);
        }

        return NoResult::instance();
    }

    /**
     * Run All in a transaction: MULTI, each command (Redis queues it), EXEC. A command Redis
     * refuses to queue discards the transaction, so nothing runs.
     *
     * @param array<int, array<string, mixed>> $commands
     */
    private static function runMulti(array $commands, callable $execute, string $origin, ?string $connection, int $maxElements, ?int $db): void
    {
        $count = count($commands);
        foreach ($commands as $index => $command) {
            if (in_array(strtoupper((string) $command['argv'][0]), RedisCommands::TRANSACTION, true)) {
                throw new RedisRefused('Command ' . ($index + 1) . ' (line ' . (int) $command['line'] . ') is ' . strtoupper((string) $command['argv'][0]) . ', and Run All already wraps the commands in MULTI/EXEC. Turn off "In a Transaction" to run them as written.');
            }
        }
        $started = hrtime(true);
        $begin = $execute(['MULTI'], 1, new RedisReplyBudget());
        if (($begin['t'] ?? '') === '-') {
            throw new RedisCommandFailed('Redis refused MULTI: ' . (string) $begin['v'] . ' Nothing ran.');
        }
        foreach ($commands as $index => $command) {
            $argv = array_map('strval', array_values($command['argv']));
            $queued = $execute($argv, 1, new RedisReplyBudget());
            if (($queued['t'] ?? '') === '-') {
                $execute(['DISCARD'], 1, new RedisReplyBudget());
                throw new RedisCommandFailed('Command ' . ($index + 1) . ' of ' . $count . ' (line ' . (int) $command['line'] . '): ' . (string) $queued['v'] . "\n\nRedis didn't queue it, so Runlet discarded the transaction: nothing ran.");
            }
        }
        $budget = new RedisReplyBudget();
        $cap = 1;
        foreach ($commands as $command) {
            $cap = max($cap, (int) ($command['cap'] ?? $maxElements));
        }
        $replies = $execute(['EXEC'], max($count, $cap), $budget);
        $elapsed = round((hrtime(true) - $started) / 1e6, 3);
        if (($replies['t'] ?? '') === '-') {
            throw new RedisCommandFailed('EXEC failed: ' . (string) $replies['v'] . ' Redis ran none of the commands.');
        }
        if (($replies['t'] ?? '') === 'n') {
            throw new RedisCommandFailed('Redis aborted the transaction (a WATCHed key changed), so none of the commands ran.');
        }
        $items = is_array($replies['v'] ?? null) ? $replies['v'] : [];
        foreach ($commands as $index => $command) {
            $argv = array_map('strval', array_values($command['argv']));
            $reply = $items[$index] ?? ['t' => 'n'];
            $event = self::event($argv, $command, $reply, $index === 0 ? $elapsed : null, $origin, $connection, $db, $maxElements, $budget);
            $event['transaction'] = true;
            $event['statement'] = ['index' => $index + 1, 'count' => $count, 'line' => (int) $command['line'], 'text' => self::echoLine($argv, $command)];
            if ($index === 0 && self::$names !== []) {
                $event['connections'] = self::$names;
            }
            Channel::emit('redis', $event);
            if (strtoupper($argv[0]) === 'SELECT' && ($reply['t'] ?? '') === '+') {
                $db = (int) ($argv[1] ?? 0);
            }
        }
        $errors = 0;
        foreach ($items as $item) {
            if (is_array($item) && ($item['t'] ?? '') === '-') {
                $errors++;
            }
        }
        Channel::emit('notice', ['message' => 'Ran ' . ($count === 1 ? 'the command' : 'all ' . $count . ' commands') . ' in one MULTI/EXEC transaction' . ($errors > 0 ? ': ' . $errors . ' of them returned an error, and Redis ran the others (it has no rollback).' : '.')]);
    }

    /**
     * @param string[] $argv
     * @param array<string, mixed> $command
     * @param array<string, mixed> $reply
     * @return array<string, mixed>
     */
    private static function event(array $argv, array $command, array $reply, ?float $elapsed, string $origin, ?string $connection, ?int $db, int $maxElements, RedisReplyBudget $budget): array
    {
        $event = [
            'argv' => self::echoArguments($argv, $command),
            'reply' => $reply,
            'source' => $origin,
            'maxElements' => $maxElements,
            'bytes' => $budget->used,
        ];
        if ($elapsed !== null) {
            $event['elapsedMs'] = $elapsed;
        }
        if (RedisConnect::isConfigured()) {
            $event['connection'] = RedisConnect::name();
            $event['saved'] = true;
        } elseif ($connection !== null) {
            $event['connection'] = $connection;
        }
        if ($db !== null) {
            $event['db'] = $db;
        }

        return $event;
    }

    /**
     * The arguments as echoed: passwords as •••, long ones shortened, bytes that aren't UTF-8
     * as \xHH.
     *
     * @param string[] $argv
     * @param array<string, mixed> $command
     * @return string[]
     */
    private static function echoArguments(array $argv, array $command): array
    {
        $secrets = array_map('intval', (array) ($command['secret'] ?? []));
        $echo = [];
        foreach (array_slice($argv, 0, self::MAX_ARGUMENTS_ECHOED) as $index => $argument) {
            if (in_array($index, $secrets, true)) {
                $echo[] = '•••';
                continue;
            }
            // Control characters, and bytes that aren't UTF-8, as \xHH.
            $argument = preg_replace_callback(preg_match('//u', $argument) === 1 ? '/[\x00-\x1f\x7f]/' : '/[\x00-\x1f\x7f-\xff]/', static function (array $match): string {
                return '\\x' . strtoupper(bin2hex($match[0]));
            }, $argument) ?? '';
            if (strlen($argument) > self::MAX_ARGUMENT_ECHO) {
                $cut = substr($argument, 0, self::MAX_ARGUMENT_ECHO);
                while ($cut !== '' && preg_match('//u', $cut) !== 1) {
                    $cut = substr($cut, 0, -1);
                }
                $argument = $cut . '…';
            }
            $echo[] = $argument;
        }
        if (count($argv) > self::MAX_ARGUMENTS_ECHOED) {
            $echo[] = '… ' . (count($argv) - self::MAX_ARGUMENTS_ECHOED) . ' more';
        }

        return $echo;
    }

    /** @param string[] $argv */
    private static function echoLine(array $argv, array $command): string
    {
        return implode(' ', self::echoArguments($argv, $command));
    }

    /**
     * Read-only saved connections: refuses the whole run, before anything is sent, when a
     * command isn't a read by Runlet's table; with `$execute`, also by the server's COMMAND
     * INFO flags (`write`), when the server answers it.
     *
     * @param array<int, array<string, mixed>> $commands
     */
    private static function refuseOnReadOnly(array $commands, ?callable $execute): void
    {
        if (!RedisConnect::isConfigured() || !RedisConnect::isReadOnly()) {
            return;
        }
        $count = count($commands);
        $name = '"' . RedisConnect::name() . '"';
        $flags = [];
        foreach ($commands as $index => $command) {
            $argv = array_map('strval', array_values((array) $command['argv']));
            $why = RedisCommands::readOnlyRefusal($argv);
            if ($why === null && $execute !== null) {
                $key = RedisCommands::key($argv);
                if (!array_key_exists($key, $flags)) {
                    $flags[$key] = self::commandFlags($execute, $key);
                }
                if (is_array($flags[$key]) && in_array('write', $flags[$key], true)) {
                    $why = 'can change data (the server flags ' . RedisCommands::name($argv) . ' as a write)';
                }
            }
            if ($why === null) {
                continue;
            }
            throw new RedisRefused($count === 1
                ? 'Runlet refused this command on the read-only connection ' . $name . ': it ' . $why . '. Nothing ran.'
                : 'Command ' . ($index + 1) . ' of ' . $count . ' (line ' . (int) $command['line'] . ') ' . $why . ', so Runlet ran none of them on the read-only connection ' . $name . '. Nothing ran.');
        }
    }

    /**
     * The server's flags for a command (`COMMAND INFO get`, `COMMAND INFO config|get`); null
     * when the server doesn't answer (COMMAND renamed or refused).
     *
     * @return string[]|null
     */
    private static function commandFlags(callable $execute, string $key): ?array
    {
        $reply = $execute(['COMMAND', 'INFO', strtolower($key)], 20, new RedisReplyBudget());
        $info = $reply['v'][0] ?? null;
        if (($reply['t'] ?? '') !== '*' || !is_array($info) || ($info['t'] ?? '') !== '*') {
            return null;
        }
        $flags = $info['v'][2]['v'] ?? null;
        if (!is_array($flags)) {
            return null;
        }
        $names = [];
        foreach ($flags as $flag) {
            if (is_array($flag) && isset($flag['v']) && is_string($flag['v'])) {
                $names[] = strtolower($flag['v']);
            }
        }

        return $names;
    }

    /**
     * #144, #180: the connection's client id, for the Connection Manager (Stop closes the
     * connection; Redis unblocks a blocked client when it does).
     */
    private static function reportSession(callable $execute, ?string $connection): void
    {
        try {
            $reply = $execute(['CLIENT', 'ID'], 1, new RedisReplyBudget());
        } catch (\Throwable $error) {
            return;
        }
        if (($reply['t'] ?? '') !== 'i') {
            return;
        }
        Channel::emit('sqlSession', array_filter([
            'driver' => 'redis',
            'id' => (int) $reply['v'],
            'connection' => RedisConnect::isConfigured() ? null : $connection,
            'saved' => RedisConnect::isConfigured() ? true : null,
        ], static function ($value): bool {
            return $value !== null;
        }));
    }

    /**
     * The connection to use, as an executor, and where it came from.
     *
     * @return array{0: callable, 1: string}
     */
    public static function resolve(?string $connection): array
    {
        if (self::$executor !== null) {
            return [self::$executor, self::$origin];
        }
        if (RedisConnect::isConfigured()) {
            $client = RedisConnect::client();
            self::$executor = static function (array $argv, int $cap, RedisReplyBudget $budget) use ($client): array {
                return $client->command($argv, $cap, $budget);
            };
            self::$origin = RedisConnect::origin();

            return [self::$executor, self::$origin];
        }
        $driver = Runner::bootedDriver();
        $what = $connection === null ? 'the default Redis connection' : 'the Redis connection "' . $connection . '"';
        if ($driver !== null && method_exists($driver, 'redisConnections')) {
            try {
                $names = Runner::callBootedDriver('redisConnections()', static function () use ($driver) {
                    return $driver->redisConnections();
                });
                foreach (is_array($names) ? $names : [] as $name) {
                    if ((is_string($name) || is_int($name)) && (string) $name !== '' && strlen((string) $name) <= 200 && !in_array((string) $name, self::$names, true)) {
                        self::$names[] = (string) $name;
                    }
                }
                self::$names = array_slice(self::$names, 0, 100);
            } catch (DriverFailure $failure) {
                throw $failure;
            } catch (\Throwable $error) {
                Channel::emit('notice', ['message' => 'The Redis connection list is unavailable: ' . $error->getMessage()]);
            }
        }
        $known = self::$names === [] ? '' : ' Connections: ' . implode(', ', self::$names) . '.';
        $value = null;
        if ($driver !== null && method_exists($driver, 'redisConnection')) {
            try {
                $value = Runner::callBootedDriver('redisConnection()', static function () use ($driver, $connection) {
                    return $driver->redisConnection($connection);
                });
            } catch (DriverFailure $failure) {
                throw $failure;
            } catch (\Throwable $error) {
                throw new RedisConnectionFailed('Runlet could not open ' . $what . ': ' . $error->getMessage() . $known, 0, $error);
            }
        }
        if ($value === null) {
            $name = $driver === null ? 'none' : $driver->name();
            throw new RedisUnavailable('This project has no Redis connection that Redis tabs can use. Its driver (' . $name . ') provides none. '
                . 'To run Redis commands here, save a Redis connection (New Connection… in the Redis bar\'s connection menu; its password goes to the Keychain), or return one from redisConnection() in a project driver (.runlet/<Name>Driver.php; see "Redis connections" in the drivers guide).');
        }
        $declaring = (new \ReflectionMethod($driver, 'redisConnection'))->getDeclaringClass()->getName();
        $origin = $declaring === 'Runlet\Drivers\LaravelDriver' ? 'Laravel Redis::connection()' : $declaring . '::redisConnection()';
        try {
            self::$executor = RedisAppConnection::executor($value, $origin);
        } catch (RedisUnavailable | RedisConnectionFailed $refused) {
            throw $refused;
        }
        self::$origin = $origin;

        return [self::$executor, self::$origin];
    }

    /** Test Connection for a saved Redis connection: emits an `sqlTest` event. */
    public static function test(): NoResult
    {
        if (!RedisConnect::isConfigured()) {
            throw new RedisUnavailable('Test Connection needs a saved connection, and this run has none.');
        }
        Channel::emit('sqlTest', RedisConnect::test());

        return NoResult::instance();
    }

    /** Selects `$db` on the connection when it isn't selected yet (key browser). */
    private static function select(callable $execute, int $db): void
    {
        $reply = $execute(['SELECT', (string) $db], 1, new RedisReplyBudget());
        if (($reply['t'] ?? '') === '-') {
            throw new RedisCommandFailed('Redis refused SELECT ' . $db . ': ' . (string) $reply['v']);
        }
    }

    /**
     * The key browser: one SCAN page of `$db` (never KEYS), with each key's TYPE and PTTL,
     * and the keyspace (INFO keyspace) for the database picker. Emits `redisKeys`. Without
     * `$details` (Load Keys for Completion, #206) it sends the SCAN only: key names, nothing else.
     */
    public static function keys(int $db, string $pattern, string $cursor, int $count, ?string $type, ?string $connection, bool $details = true): NoResult
    {
        [$execute, $origin] = self::resolve($connection === '' ? null : $connection);
        self::select($execute, $db);
        $started = hrtime(true);
        $argv = ['SCAN', $cursor === '' ? '0' : $cursor, 'MATCH', $pattern === '' ? '*' : $pattern, 'COUNT', (string) max(1, min(10000, $count))];
        if ($type !== null && $type !== '') {
            $argv[] = 'TYPE';
            $argv[] = $type;
        }
        $reply = $execute($argv, 10000, new RedisReplyBudget());
        if (($reply['t'] ?? '') === '-') {
            throw new RedisCommandFailed('SCAN failed: ' . (string) $reply['v']);
        }
        $next = (string) ($reply['v'][0]['v'] ?? '0');
        $names = [];
        foreach ((array) ($reply['v'][1]['v'] ?? []) as $item) {
            if (is_array($item) && ($item['t'] ?? '') === 's') {
                $names[] = (string) $item['v'];
            }
        }
        $keys = [];
        foreach ($names as $name) {
            if (!$details) {
                $keys[] = array_filter([
                    'key' => preg_match('//u', $name) === 1 ? $name : null,
                    'raw' => base64_encode($name),
                ], static function ($value): bool {
                    return $value !== null;
                });
                continue;
            }
            $keyType = $execute(['TYPE', $name], 1, new RedisReplyBudget());
            $ttl = $execute(['PTTL', $name], 1, new RedisReplyBudget());
            $keys[] = array_filter([
                'key' => preg_match('//u', $name) === 1 ? $name : null,
                'raw' => base64_encode($name),
                'type' => ($keyType['t'] ?? '') === '+' ? (string) $keyType['v'] : null,
                'ttl' => ($ttl['t'] ?? '') === 'i' ? (int) $ttl['v'] : null,
            ], static function ($value): bool {
                return $value !== null;
            });
        }
        $keyspace = [];
        $info = $details ? $execute(['INFO', 'keyspace'], 1, new RedisReplyBudget()) : [];
        if (($info['t'] ?? '') === 's' && preg_match_all('/^db(\d+):keys=(\d+),expires=(\d+)/m', (string) $info['v'], $matches, PREG_SET_ORDER) > 0) {
            foreach ($matches as $match) {
                $keyspace[] = ['db' => (int) $match[1], 'keys' => (int) $match[2], 'expires' => (int) $match[3]];
            }
        }
        $databases = null;
        $config = $details ? $execute(['CONFIG', 'GET', 'databases'], 2, new RedisReplyBudget()) : [];
        if (($config['t'] ?? '') === '*' && isset($config['v'][1]['v'])) {
            $databases = (int) $config['v'][1]['v'];
        }
        Channel::emit('redisKeys', array_filter([
            'db' => $db,
            'pattern' => $pattern,
            'cursor' => $cursor,
            'next' => $next,
            'keys' => $keys,
            'keyspace' => $keyspace,
            'databases' => $databases,
            'source' => $origin,
            'connections' => self::$names === [] ? null : self::$names,
            'elapsedMs' => round((hrtime(true) - $started) / 1e6, 3),
        ], static function ($value): bool {
            return $value !== null;
        }));

        return NoResult::instance();
    }

    /**
     * The key browser's Open Value: the key's value read by its type, as a `redis` event whose
     * `argv` is the equivalent command (so it shows like a tab's reply).
     */
    public static function value(int $db, string $key, int $maxElements, ?string $connection): NoResult
    {
        [$execute, $origin] = self::resolve($connection === '' ? null : $connection);
        self::select($execute, $db);
        $maxElements = max(1, $maxElements);
        $type = $execute(['TYPE', $key], 1, new RedisReplyBudget());
        $kind = ($type['t'] ?? '') === '+' ? (string) $type['v'] : 'none';
        $budget = new RedisReplyBudget();
        $started = hrtime(true);
        switch ($kind) {
            case 'string':
                $argv = ['GET', $key];
                $reply = $execute($argv, 1, $budget);
                break;
            case 'hash':
                $argv = ['HGETALL', $key];
                $reply = self::scanned($execute, 'HSCAN', $key, $maxElements, $budget, true);
                break;
            case 'list':
                $argv = ['LRANGE', $key, '0', (string) ($maxElements - 1)];
                $reply = $execute($argv, $maxElements, $budget);
                $length = $execute(['LLEN', $key], 1, new RedisReplyBudget());
                if (($length['t'] ?? '') === 'i' && (int) $length['v'] > count((array) ($reply['v'] ?? []))) {
                    $reply['o'] = (int) $length['v'] - count((array) $reply['v']);
                }
                break;
            case 'set':
                $argv = ['SMEMBERS', $key];
                $reply = self::scanned($execute, 'SSCAN', $key, $maxElements, $budget, false);
                break;
            case 'zset':
                $argv = ['ZRANGE', $key, '0', (string) ($maxElements - 1), 'WITHSCORES'];
                $reply = $execute($argv, $maxElements * 2, $budget);
                $length = $execute(['ZCARD', $key], 1, new RedisReplyBudget());
                if (($length['t'] ?? '') === 'i' && (int) $length['v'] * 2 > count((array) ($reply['v'] ?? []))) {
                    $reply['o'] = (int) $length['v'] * 2 - count((array) $reply['v']);
                }
                break;
            case 'stream':
                $argv = ['XRANGE', $key, '-', '+', 'COUNT', (string) $maxElements];
                $reply = $execute($argv, $maxElements, $budget);
                $length = $execute(['XLEN', $key], 1, new RedisReplyBudget());
                if (($length['t'] ?? '') === 'i' && (int) $length['v'] > count((array) ($reply['v'] ?? []))) {
                    $reply['o'] = (int) $length['v'] - count((array) $reply['v']);
                }
                break;
            case 'none':
                throw new RedisCommandFailed('The key doesn\'t exist any more (it expired or was deleted).');
            default:
                $argv = ['TYPE', $key];
                $reply = ['t' => '+', 'v' => $kind];
                Channel::emit('notice', ['message' => 'The key is a ' . $kind . ', which Runlet doesn\'t read by itself: run the module\'s own command in the Redis tab.']);
        }
        $event = self::event($argv, [], $reply, round((hrtime(true) - $started) / 1e6, 3), $origin, $connection, $db, $maxElements, $budget);
        if (self::$names !== []) {
            $event['connections'] = self::$names;
        }
        Channel::emit('redis', $event);

        return NoResult::instance();
    }

    /**
     * A hash's or set's elements through HSCAN/SSCAN (never one call for a huge key), until
     * `$maxElements` rows or the end; the rest are counted (HLEN/SCARD).
     *
     * @return array<string, mixed>
     */
    private static function scanned(callable $execute, string $command, string $key, int $maxElements, RedisReplyBudget $budget, bool $pairs): array
    {
        $items = [];
        $cursor = '0';
        $rows = 0;
        $rounds = 0;
        do {
            $page = $execute([$command, $key, $cursor, 'COUNT', '500'], 2000, $budget);
            if (($page['t'] ?? '') === '-') {
                return $page;
            }
            $cursor = (string) ($page['v'][0]['v'] ?? '0');
            foreach ((array) ($page['v'][1]['v'] ?? []) as $item) {
                $items[] = $item;
            }
            $rows = $pairs ? intdiv(count($items), 2) : count($items);
            $rounds++;
        } while ($cursor !== '0' && $rows < $maxElements && !$budget->exhausted() && $rounds < 10000);
        $keep = $pairs ? $maxElements * 2 : $maxElements;
        $omitted = max(0, count($items) - $keep);
        $items = array_slice($items, 0, $keep);
        $total = $execute([$pairs ? 'HLEN' : 'SCARD', $key], 1, new RedisReplyBudget());
        if (($total['t'] ?? '') === 'i') {
            $omitted = max($omitted, ((int) $total['v']) * ($pairs ? 2 : 1) - count($items));
        }
        $node = ['t' => '*', 'v' => $items];
        if ($omitted > 0) {
            $node['o'] = $omitted;
        }

        return $node;
    }

    /**
     * The key browser's Memory Usage: the key's type, TTL, encoding, length, and MEMORY USAGE.
     * Emits `redisKeyInfo`.
     */
    public static function keyInfo(int $db, string $key, ?string $connection): NoResult
    {
        [$execute] = self::resolve($connection === '' ? null : $connection);
        self::select($execute, $db);
        $type = $execute(['TYPE', $key], 1, new RedisReplyBudget());
        $kind = ($type['t'] ?? '') === '+' ? (string) $type['v'] : null;
        $ttl = $execute(['PTTL', $key], 1, new RedisReplyBudget());
        $encoding = $execute(['OBJECT', 'ENCODING', $key], 1, new RedisReplyBudget());
        $memory = $execute(['MEMORY', 'USAGE', $key], 1, new RedisReplyBudget());
        $lengthCommand = ['string' => 'STRLEN', 'hash' => 'HLEN', 'list' => 'LLEN', 'set' => 'SCARD', 'zset' => 'ZCARD', 'stream' => 'XLEN'][$kind ?? ''] ?? null;
        $length = $lengthCommand === null ? null : $execute([$lengthCommand, $key], 1, new RedisReplyBudget());
        Channel::emit('redisKeyInfo', array_filter([
            'raw' => base64_encode($key),
            'type' => $kind,
            'ttl' => ($ttl['t'] ?? '') === 'i' ? (int) $ttl['v'] : null,
            'encoding' => ($encoding['t'] ?? '') === 's' ? (string) $encoding['v'] : null,
            'memory' => ($memory['t'] ?? '') === 'i' ? (int) $memory['v'] : null,
            'memoryError' => ($memory['t'] ?? '') === '-' ? (string) $memory['v'] : null,
            'length' => is_array($length) && ($length['t'] ?? '') === 'i' ? (int) $length['v'] : null,
        ], static function ($value): bool {
            return $value !== null;
        }));

        return NoResult::instance();
    }

    /**
     * The server panel: INFO (every default section), CLIENT LIST, and this connection's own
     * CLIENT ID. Emits `redisServer` with the raw texts (the app parses them).
     */
    public static function server(?string $connection): NoResult
    {
        [$execute, $origin] = self::resolve($connection === '' ? null : $connection);
        $started = hrtime(true);
        $info = $execute(['INFO'], 1, new RedisReplyBudget());
        $clients = $execute(['CLIENT', 'LIST'], 1, new RedisReplyBudget());
        $own = $execute(['CLIENT', 'ID'], 1, new RedisReplyBudget());
        Channel::emit('redisServer', array_filter([
            'info' => ($info['t'] ?? '') === 's' ? (string) $info['v'] : null,
            'infoError' => ($info['t'] ?? '') === '-' ? (string) $info['v'] : null,
            'clients' => ($clients['t'] ?? '') === 's' ? (string) $clients['v'] : null,
            'clientsError' => ($clients['t'] ?? '') === '-' ? (string) $clients['v'] : null,
            'ownId' => ($own['t'] ?? '') === 'i' ? (int) $own['v'] : null,
            'source' => $origin,
            'connection' => RedisConnect::isConfigured() ? RedisConnect::name() : $connection,
            'saved' => RedisConnect::isConfigured() ? true : null,
            'elapsedMs' => round((hrtime(true) - $started) / 1e6, 3),
        ], static function ($value): bool {
            return $value !== null;
        }));

        return NoResult::instance();
    }

    /**
     * The server panel's Kill Client, confirmed in the app: refuses another server (INFO's
     * run_id), the panel's own client (`$listedBy`), this runner's own, and a client that isn't
     * the one listed any more (its address changed or it's gone); then CLIENT KILL ID. Emits
     * `redisKill`.
     */
    public static function kill(int $clientId, string $address, string $runId, int $listedBy, ?string $connection): NoResult
    {
        [$execute] = self::resolve($connection === '' ? null : $connection);
        $report = static function (string $outcome, string $detail) use ($clientId): NoResult {
            Channel::emit('redisKill', ['id' => $clientId, 'outcome' => $outcome, 'detail' => $detail]);

            return NoResult::instance();
        };
        $info = $execute(['INFO', 'server'], 1, new RedisReplyBudget());
        $actual = ($info['t'] ?? '') === 's' && preg_match('/^run_id:(\S+)/m', (string) $info['v'], $match) === 1 ? $match[1] : '';
        if ($runId !== '' && $actual !== $runId) {
            return $report('refused', 'This connection reached another Redis server than the one the list came from (its run_id differs), so Runlet killed nothing. Refresh the list.');
        }
        $own = $execute(['CLIENT', 'ID'], 1, new RedisReplyBudget());
        if ($clientId === $listedBy || (($own['t'] ?? '') === 'i' && (int) $own['v'] === $clientId)) {
            return $report('refused', 'Client ' . $clientId . ' is Runlet\'s own connection, so it wasn\'t killed.');
        }
        $listed = $execute(['CLIENT', 'LIST', 'ID', (string) $clientId], 1, new RedisReplyBudget());
        $line = ($listed['t'] ?? '') === 's' ? trim((string) $listed['v']) : '';
        if ($line === '') {
            return $report('gone', 'Client ' . $clientId . ' isn\'t connected any more.');
        }
        if ($address !== '' && preg_match('/(?:^| )addr=(\S+)/', $line, $match) === 1 && $match[1] !== $address) {
            return $report('refused', 'Client ' . $clientId . ' now connects from ' . $match[1] . ', not ' . $address . ' as listed, so Runlet killed nothing. Refresh the list.');
        }
        $killed = $execute(['CLIENT', 'KILL', 'ID', (string) $clientId], 1, new RedisReplyBudget());
        if (($killed['t'] ?? '') === '-') {
            return $report('failed', 'Redis refused CLIENT KILL: ' . (string) $killed['v']);
        }
        if (($killed['t'] ?? '') === 'i' && (int) $killed['v'] === 0) {
            return $report('gone', 'Client ' . $clientId . ' had already disconnected.');
        }

        return $report('killed', 'Killed client ' . $clientId . ' (CLIENT KILL ID ' . $clientId . ').');
    }
}
