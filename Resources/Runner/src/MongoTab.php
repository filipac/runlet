<?php

declare(strict_types=1);

namespace RunletRunner;

final class MongoTab
{
    private static $definition;
    private static $password;

    public static function configure(array $definition): void
    {
        self::$password = (string) ($definition['password'] ?? '');
        Channel::addSecret(self::$password);
        unset($definition['password']);
        self::$definition = $definition;
    }

    private static function connect(?string $name): array
    {
        if (!extension_loaded('mongodb')) {
            throw new \RuntimeException('MongoDB needs ext-mongodb. Choose Connect from this Mac with a PHP that has it, or install ext-mongodb on the target.');
        }
        if (self::$definition === null) {
            $driver = Runner::bootedDriver();
            if ($driver !== null && method_exists($driver, 'mongoConnection')) {
                $connection = Runner::callBootedDriver('mongoConnection()', static function () use ($driver, $name) { return $driver->mongoConnection($name); });
                if (is_array($connection) && ($connection['manager'] ?? null) instanceof \MongoDB\Driver\Manager && is_string($connection['database'] ?? null)) {
                    return [$connection['manager'], $connection['database']];
                }
            }
            if (class_exists('Illuminate\Support\Facades\DB')) {
                $connection = \Illuminate\Support\Facades\DB::connection($name ?? 'mongodb');
                if (method_exists($connection, 'getMongoClient')) {
                    return [$connection->getMongoClient()->getManager(), $connection->getDatabaseName()];
                }
            }
            throw new \RuntimeException('Choose a saved MongoDB connection, a Laravel MongoDB connection, or a project driver mongoConnection() hook.');
        }
        $definition = self::$definition;
        $mongo = $definition['mongo'] ?? [];
        $host = (string) ($definition['host'] ?? '');
        if (!preg_match('/^[A-Za-z0-9._:\[\]-]+$/D', $host)) { throw new \RuntimeException('Invalid MongoDB host.'); }
        $srv = ($mongo['srv'] ?? false) === true;
        $tunnel = $definition['tunnel'] ?? null;
        if ($srv && $tunnel !== null) { throw new \RuntimeException('SRV cannot use an SSH tunnel.'); }
        $port = (int) ($definition['port'] ?? 27017);
        if ($port < 1 || $port > 65535) { throw new \RuntimeException('Invalid MongoDB port.'); }
        if ($tunnel !== null) { $host = '127.0.0.1'; $port = (int) $tunnel['port']; }
        if (strpos($host, ':') !== false && $host[0] !== '[') { $host = '[' . $host . ']'; }
        $uri = ($srv ? 'mongodb+srv://' : 'mongodb://') . $host . ($srv ? '' : ':' . $port);
        $timeout = max(1, min(300, (int) ($definition['timeout'] ?? 10))) * 1000;
        $options = ['connectTimeoutMS' => $timeout, 'serverSelectionTimeoutMS' => $timeout, 'socketTimeoutMS' => 30000, 'appname' => 'Runlet'];
        if (($definition['user'] ?? '') !== '') {
            $options['username'] = $definition['user'];
            $options['password'] = self::$password;
            $options['authSource'] = $mongo['authDatabase'] ?? 'admin';
        }
        foreach (['authMechanism', 'replicaSet', 'readPreference'] as $key) {
            if (($mongo[$key] ?? '') !== '') { $options[$key] = $mongo[$key]; }
        }
        if ($tunnel !== null) { $options['directConnection'] = true; }
        if (isset($definition['tls']['mode'])) {
            if (!in_array($definition['tls']['mode'], ['disable', 'verify-full'], true)) { throw new \RuntimeException('Unsupported MongoDB TLS mode.'); }
            $options['tls'] = $definition['tls']['mode'] === 'verify-full';
        }
        try {
            $manager = new \MongoDB\Driver\Manager($uri, $options);
        } finally {
            self::$password = null;
            unset($options['password']);
        }
        return [$manager, (string) ($definition['database'] ?? '')];
    }

    public static function validate(string $json): array
    {
        if (strlen($json) > 1048576) { throw new \RuntimeException('MongoDB query exceeds 1 MiB.'); }
        $query = json_decode($json);
        if (!$query instanceof \stdClass) { throw new \RuntimeException('Enter one MongoDB JSON query object.'); }
        $fields = [
            'find' => ['filter', 'projection', 'sort', 'skip', 'limit', 'explain'],
            'findOne' => ['filter', 'projection', 'sort'],
            'aggregate' => ['pipeline', 'explain'], 'countDocuments' => ['filter'],
            'distinct' => ['filter', 'field'], 'getIndexes' => [],
            'insertOne' => ['documents'], 'insertMany' => ['documents'],
            'updateOne' => ['filter', 'update'], 'updateMany' => ['filter', 'update'],
            'replaceOne' => ['filter', 'replacement'], 'deleteOne' => ['filter'],
            'deleteMany' => ['filter'], 'drop' => [], 'createIndex' => ['keys', 'unique'],
            'listDatabases' => [], 'listCollections' => [], 'sampleSchema' => [],
            'dropDatabase' => ['database'],
        ];
        $operation = $query->operation ?? '';
        if (!is_string($operation) || !isset($fields[$operation])) { throw new \RuntimeException('Unsupported MongoDB operation.'); }
        if (array_diff(array_keys(get_object_vars($query)), array_merge($operation === 'dropDatabase' ? ['operation'] : ['collection', 'operation'], $fields[$operation]))) { throw new \RuntimeException('Unknown fields for this MongoDB operation.'); }
        if ($operation === 'dropDatabase') {
            // #207: the query names the database; run() checks it is the connection's.
            $name = $query->database ?? '';
            if (!is_string($name) || $name === '' || strlen($name) > 63 || preg_match('/[\/\\\\. "$*<>:|?\x00]/', $name) || in_array(strtolower($name), ['admin', 'local', 'config'], true)) { throw new \RuntimeException('dropDatabase names the connection\'s database (admin, local and config can\'t be dropped).'); }
            $query->collection = '';
        } else {
            $collection = $query->collection ?? '';
            if (!is_string($collection) || $collection === '' || strlen($collection) > 120 || strpos($collection, "\0") !== false || strpos($collection, 'system.') === 0) { throw new \RuntimeException('Invalid collection name.'); }
        }
        foreach (['filter', 'projection', 'sort', 'update', 'replacement', 'keys'] as $key) {
            if (property_exists($query, $key) && !$query->$key instanceof \stdClass) { throw new \RuntimeException($key . ' must be an object.'); }
        }
        foreach (['skip', 'limit'] as $key) {
            if (property_exists($query, $key) && (!is_int($query->$key) || $query->$key < 0 || $query->$key > 1000000)) { throw new \RuntimeException($key . ' must be an integer from 0 to 1000000.'); }
        }
        foreach (['explain', 'unique'] as $key) {
            if (property_exists($query, $key) && !is_bool($query->$key)) { throw new \RuntimeException($key . ' must be boolean.'); }
        }
        if ($operation === 'aggregate') {
            if (!isset($query->pipeline) || !is_array($query->pipeline)) { throw new \RuntimeException('aggregate requires a pipeline array.'); }
            foreach ($query->pipeline as $stage) {
                if (!$stage instanceof \stdClass || count(get_object_vars($stage)) !== 1) { throw new \RuntimeException('Each pipeline stage must be a single-key object.'); }
            }
        }
        if ($operation === 'distinct' && (!isset($query->field) || !is_string($query->field) || $query->field === '')) { throw new \RuntimeException('distinct requires field.'); }
        if (strpos($operation, 'insert') === 0) {
            if (!isset($query->documents) || !is_array($query->documents) || count($query->documents) < 1 || count($query->documents) > 1000 || ($operation === 'insertOne' && count($query->documents) !== 1)) { throw new \RuntimeException('Insert requires documents.'); }
            foreach ($query->documents as $document) { if (!$document instanceof \stdClass) { throw new \RuntimeException('Each document must be an object.'); } }
        }
        foreach (['updateOne' => 'update', 'updateMany' => 'update', 'replaceOne' => 'replacement', 'createIndex' => 'keys'] as $method => $key) {
            if ($operation === $method && (!isset($query->$key) || ($key !== 'replacement' && count(get_object_vars($query->$key)) === 0))) { throw new \RuntimeException($operation . ' requires ' . $key . '.'); }
        }
        if (self::hasKey($query, ['$where', '$function', '$accumulator', '$code'])) { throw new \RuntimeException('Server-side JavaScript is not supported.'); }
        $read = in_array($operation, ['find', 'findOne', 'aggregate', 'countDocuments', 'distinct', 'getIndexes', 'listDatabases', 'listCollections', 'sampleSchema'], true) && !self::hasKey($query->pipeline ?? [], ['$out', '$merge']);
        $destructive = $operation === 'drop' || $operation === 'dropDatabase' || (in_array($operation, ['deleteMany', 'updateMany'], true) && count(get_object_vars($query->filter ?? new \stdClass())) === 0);
        if (($query->explain ?? false) && !$read) { throw new \RuntimeException('Explain is available only for reads.'); }
        return [$query, $read, $destructive];
    }

    private static function hasKey($value, array $keys): bool
    {
        if (!is_array($value) && !is_object($value)) { return false; }
        foreach ($value as $key => $child) {
            if (in_array($key, $keys, true) || self::hasKey($child, $keys)) { return true; }
        }
        return false;
    }

    public static function run(array $request): NoResult
    {
        ini_set('zend.exception_ignore_args', '1');
        [$query, $read, $destructive] = self::validate((string) ($request['query'] ?? ''));
        if ((self::$definition['readOnly'] ?? false) && !$read) { throw new \RuntimeException('Read-only MongoDB connection refused ' . $query->operation . '. Nothing ran.'); }
        if ($destructive && ($request['confirmed'] ?? false) !== true) { throw new \RuntimeException('Confirm MongoDB ' . $query->operation . ' before running.'); }
        try {
            [$manager, $database] = self::connect($request['connection'] ?? null);
            if ($database === '') { throw new \RuntimeException('Choose a database in the connection settings.'); }
            if ($query->operation === 'dropDatabase' && $query->database !== $database) {
                throw new \RuntimeException('dropDatabase names “' . $query->database . '”, but the connection\'s database is “' . $database . '”. Nothing ran.');
            }
            $query = class_exists('MongoDB\BSON\Document')
                ? \MongoDB\BSON\Document::fromJSON(json_encode($query))->toPHP()
                : \MongoDB\BSON\toPHP(\MongoDB\BSON\fromJSON(json_encode($query)));
            $size = max(1, min(1000, (int) ($request['pageSize'] ?? 100)));
            $offset = max(0, min(1000000, (int) ($request['offset'] ?? 0)));
            // #207: the operation runs on one selected server (the read preference's for reads, the
            // primary for writes), tagged with the run's id, so Stop can find it there and kill it.
            $server = $manager->selectServer($read ? $manager->getReadPreference() : new \MongoDB\Driver\ReadPreference('primary'));
            $tag = self::tag($server);
            if ($tag !== null) { self::reportSession($server, $tag, $request['connection'] ?? null); }
            $started = microtime(true);
            $documents = self::execute($server, $database, $query, $size, $offset, $tag);
            $rows = [];
            $bytes = 0;
            $cut = false;
            foreach ($documents as $document) {
                $json = class_exists('MongoDB\BSON\Document')
                    ? \MongoDB\BSON\Document::fromPHP((object) $document)->toCanonicalExtendedJSON()
                    : \MongoDB\BSON\toCanonicalExtendedJSON(\MongoDB\BSON\fromPHP((object) $document));
                $bytes += strlen($json);
                if (count($rows) >= $size || $bytes > 4194304) { $cut = true; break; }
                $rows[] = self::clean(json_decode($json, true));
            }
            self::emit($rows, $query->operation, (microtime(true) - $started) * 1000, $request['connection'] ?? null);
            if ($cut) { Channel::emit('notice', ['message' => 'MongoDB output reached its document or 4 MiB size limit. Narrow the filter or projection to see the omitted data.']); }
        } catch (\Throwable $error) {
            // Runlet's own messages (a plain RuntimeException) say what to do; driver errors are replaced.
            if (!extension_loaded('mongodb') || get_class($error) === \RuntimeException::class) { throw $error; }
            throw new \RuntimeException('MongoDB ' . $query->operation . ' failed. Check the connection, permissions, and query shape. Driver code: ' . (int) $error->getCode());
        }
        return NoResult::instance();
    }

    /** Runs the operation on `$server` (#207), its commands carrying `comment: $tag` when there is one. */
    private static function execute(\MongoDB\Driver\Server $server, string $database, $query, int $size, int $offset, ?string $tag)
    {
        $manager = $server;
        $operation = $query->operation;
        $collection = $query->collection;
        $filter = $query->filter ?? new \stdClass();
        $comment = $tag === null ? [] : ['comment' => $tag];
        if ($operation === 'listDatabases') {
            $result = $manager->executeReadCommand('admin', new \MongoDB\Driver\Command(['listDatabases' => 1, 'nameOnly' => true, 'authorizedDatabases' => true] + $comment))->toArray();
            return array_slice($result[0]->databases ?? [], 0, $size);
        }
        if ($operation === 'listCollections') {
            $cursor = $manager->executeReadCommand($database, new \MongoDB\Driver\Command(['listCollections' => 1, 'nameOnly' => true, 'authorizedCollections' => true, 'cursor' => ['batchSize' => 100]] + $comment));
            $collections = [];
            foreach ($cursor as $item) {
                if (count($collections) >= 100) { break; }
                $count = null;
                try {
                    $stats = $manager->executeReadCommand($database, new \MongoDB\Driver\Command(['collStats' => $item->name, 'maxTimeMS' => 5000] + $comment))->toArray();
                    $count = $stats[0]->count ?? null;
                } catch (\Throwable $ignored) {}
                $collections[] = (object) ['name' => $item->name, 'type' => $item->type ?? 'collection', 'estimatedCount' => $count];
            }
            return $collections;
        }
        if ($operation === 'sampleSchema') {
            $cursor = $manager->executeReadCommand($database, new \MongoDB\Driver\Command(['aggregate' => $collection, 'pipeline' => [['$sample' => ['size' => 50]]], 'cursor' => new \stdClass(), 'maxTimeMS' => 10000] + $comment));
            $fields = [];
            foreach ($cursor as $document) {
                foreach ($document as $name => $value) {
                    $fields[$name][self::typeName($value)] = true;
                }
            }
            $rows = [];
            foreach ($fields as $name => $types) { $rows[] = (object) ['field' => $name, 'types' => implode(', ', array_keys($types))]; }
            return array_slice($rows, 0, 200);
        }
        if ($operation === 'find' || $operation === 'findOne') {
            $limit = $operation === 'findOne' ? 1 : min($size, max(0, ($query->limit ?? 1000000) - $offset));
            if ($limit === 0) { return []; }
            $options = ['limit' => $limit, 'skip' => ($query->skip ?? 0) + $offset, 'maxTimeMS' => 25000];
            $tagged = $options + $comment;
            foreach (['projection', 'sort'] as $key) { if (isset($query->$key)) { $options[$key] = $query->$key; } }
            if (!($query->explain ?? false)) { return $manager->executeQuery($database . '.' . $collection, new \MongoDB\Driver\Query($filter, $tagged)); }
            $command = ['explain' => ['find' => $collection, 'filter' => $filter] + $options, 'verbosity' => 'queryPlanner'] + $comment;
        } elseif ($operation === 'aggregate' || $operation === 'countDocuments') {
            $pipeline = $operation === 'countDocuments' ? [(object) ['$match' => $filter], (object) ['$count' => 'count']] : $query->pipeline;
            if (!self::hasKey($pipeline, ['$out', '$merge'])) {
                if ($offset > 0) { $pipeline[] = (object) ['$skip' => $offset]; }
                $pipeline[] = (object) ['$limit' => $size];
            }
            $command = ['aggregate' => $collection, 'pipeline' => $pipeline, 'cursor' => new \stdClass(), 'maxTimeMS' => 25000];
            $command = ($query->explain ?? false) ? ['explain' => $command, 'verbosity' => 'queryPlanner'] + $comment : $command + $comment;
        } elseif ($operation === 'distinct') {
            $result = $manager->executeReadCommand($database, new \MongoDB\Driver\Command(['distinct' => $collection, 'key' => $query->field, 'query' => $filter, 'maxTimeMS' => 25000] + $comment))->toArray();
            return array_map(static function ($value) { return (object) ['value' => $value]; }, array_slice($result[0]->values ?? [], $offset, $size));
        } elseif ($operation === 'getIndexes') {
            $command = ['listIndexes' => $collection, 'cursor' => new \stdClass()] + $comment;
        } elseif ($operation === 'dropDatabase') {
            $manager->executeWriteCommand($database, new \MongoDB\Driver\Command(['dropDatabase' => 1] + $comment));
            return [(object) ['dropped' => $database]];
        } elseif ($operation === 'drop') {
            return $manager->executeWriteCommand($database, new \MongoDB\Driver\Command(['drop' => $collection] + $comment));
        } elseif ($operation === 'createIndex') {
            $command = ['createIndexes' => $collection, 'indexes' => [['key' => $query->keys, 'name' => 'runlet_' . substr(hash('sha256', json_encode($query->keys)), 0, 12), 'unique' => $query->unique ?? false]]] + $comment;
            return $manager->executeWriteCommand($database, new \MongoDB\Driver\Command($command));
        } else {
            $bulk = new \MongoDB\Driver\BulkWrite($comment !== [] && version_compare((string) phpversion('mongodb'), '1.14.0', '>=') ? $comment : []);
            if (strpos($operation, 'insert') === 0) {
                foreach ($query->documents as $document) { $bulk->insert($document); }
            } elseif (strpos($operation, 'delete') === 0) {
                $bulk->delete($filter, ['limit' => $operation === 'deleteOne' ? 1 : 0]);
            } else {
                $bulk->update($filter, $query->update ?? $query->replacement, ['multi' => $operation === 'updateMany', 'upsert' => false]);
            }
            $result = $manager->executeBulkWrite($database . '.' . $collection, $bulk);
            return [(object) ['inserted' => $result->getInsertedCount(), 'matched' => $result->getMatchedCount(), 'modified' => $result->getModifiedCount(), 'deleted' => $result->getDeletedCount()]];
        }
        if (self::hasKey($query->pipeline ?? [], ['$out', '$merge'])) { return $manager->executeReadWriteCommand($database, new \MongoDB\Driver\Command($command)); }
        return $manager->executeReadCommand($database, new \MongoDB\Driver\Command($command));
    }

    private static function clean($value)
    {
        if (is_string($value)) { return Channel::scrub(preg_replace('~(mongodb(?:\+srv)?://)[^\s/"<>]*@~i', '$1[redacted]@', $value)); }
        if (is_array($value)) {
            $clean = [];
            foreach ($value as $key => $child) { $clean[is_string($key) ? self::clean($key) : $key] = self::clean($child); }
            return $clean;
        }
        return $value;
    }

    /**
     * A sampled value's BSON type, short (#207): ObjectId, UTCDateTime, Decimal128, Binary,
     * Timestamp, Regex, … for the extension's classes; object, array, string, int, double,
     * bool and null for the others.
     */
    public static function typeName($value): string
    {
        if (is_object($value)) {
            if ($value instanceof \stdClass || $value instanceof \MongoDB\BSON\Document) { return 'object'; }
            if ($value instanceof \MongoDB\BSON\PackedArray) { return 'array'; }
            $class = get_class($value);
            $slash = strrpos($class, '\\');
            return $slash === false ? $class : substr($class, $slash + 1);
        }
        switch (gettype($value)) {
            case 'integer': return 'int';
            case 'double': return 'double';
            case 'boolean': return 'bool';
            case 'NULL': return 'null';
            case 'array': return 'array';
            default: return 'string';
        }
    }

    /**
     * A table cell for a value of canonical Extended JSON (#207), as the tree's type tags say:
     * ObjectId("…"), a date as Runlet shows SQL dates (2026-01-01 00:00:00.000+00:00, UTC),
     * Decimal128 and doubles as their exact text, 32- and 64-bit integers as numbers, binary as
     * BinData(subtype, "base64") or UUID("…"). Documents and arrays read like mongosh:
     * { status: "paid", placed: ISODate("2026-01-01T00:00:00.000Z") }.
     */
    public static function cell($value)
    {
        if (!is_array($value)) { return $value; }
        $special = self::special($value, false);
        return $special !== null ? $special : self::shell($value);
    }

    /** mongosh-like text of a document, an array, or a value inside them. */
    private static function shell($value): string
    {
        if (!is_array($value)) { return (string) json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR); }
        $special = self::special($value, true);
        if ($special !== null) { return (string) $special; }
        if ($value === []) { return '{}'; }
        $parts = [];
        if (array_keys($value) === range(0, count($value) - 1)) {
            foreach ($value as $child) { $parts[] = self::shell($child); }
            return '[' . implode(', ', $parts) . ']';
        }
        foreach ($value as $key => $child) {
            $key = (string) $key;
            $parts[] = (preg_match('/^[A-Za-z_$][A-Za-z0-9_$]*$/D', $key) ? $key : json_encode($key, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) . ': ' . self::shell($child);
        }
        return '{ ' . implode(', ', $parts) . ' }';
    }

    /** A BSON type in canonical Extended JSON, as text (int for integers in a cell); null for others. */
    private static function special(array $value, bool $nested)
    {
        $keys = array_keys($value);
        if (count($keys) !== 1 || !is_string($keys[0]) || $keys[0] === '' || $keys[0][0] !== '$') { return null; }
        $inner = $value[$keys[0]];
        switch ($keys[0]) {
            case '$oid':
                return is_string($inner) ? 'ObjectId("' . $inner . '")' : null;
            case '$date':
                $ms = is_array($inner) && isset($inner['$numberLong']) ? $inner['$numberLong'] : $inner;
                if (is_string($ms) && preg_match('/^-?\d{1,19}$/D', $ms)) { $ms = (int) $ms; }
                if (!is_int($ms)) { return is_string($inner) ? $inner : null; }
                $seconds = intdiv($ms, 1000);
                $millis = $ms % 1000;
                if ($millis < 0) { $millis += 1000; $seconds--; }
                $date = (new \DateTimeImmutable('@' . $seconds))->setTimezone(new \DateTimeZone('UTC'));
                return $nested
                    ? 'ISODate("' . $date->format('Y-m-d\TH:i:s') . sprintf('.%03d', $millis) . 'Z")'
                    : $date->format('Y-m-d H:i:s') . sprintf('.%03d', $millis) . '+00:00';
            case '$numberInt':
            case '$numberLong':
                if (!is_string($inner) || !preg_match('/^-?\d{1,19}$/D', $inner)) { return null; }
                return $nested ? $inner : (int) $inner;
            case '$numberDouble':
                return is_string($inner) ? $inner : null;
            case '$numberDecimal':
                return is_string($inner) ? ($nested ? 'Decimal128("' . $inner . '")' : $inner) : null;
            case '$binary':
                if (!is_array($inner) || !isset($inner['base64'], $inner['subType'])) { return null; }
                $bytes = base64_decode((string) $inner['base64'], true);
                if (in_array($inner['subType'], ['03', '04'], true) && $bytes !== false && strlen($bytes) === 16) {
                    $hex = bin2hex($bytes);
                    return 'UUID("' . substr($hex, 0, 8) . '-' . substr($hex, 8, 4) . '-' . substr($hex, 12, 4) . '-' . substr($hex, 16, 4) . '-' . substr($hex, 20) . '")';
                }
                $subtype = hexdec((string) $inner['subType']);
                if (strlen((string) $inner['base64']) > 88) { return 'BinData(' . $subtype . ', ' . number_format($bytes === false ? 0 : strlen($bytes)) . ' bytes)'; }
                return 'BinData(' . $subtype . ', "' . $inner['base64'] . '")';
            case '$timestamp':
                return is_array($inner) && isset($inner['t'], $inner['i']) ? 'Timestamp({ t: ' . (int) $inner['t'] . ', i: ' . (int) $inner['i'] . ' })' : null;
            case '$regularExpression':
                return is_array($inner) && isset($inner['pattern']) ? '/' . $inner['pattern'] . '/' . ($inner['options'] ?? '') : null;
            case '$minKey':
                return 'MinKey';
            case '$maxKey':
                return 'MaxKey';
            case '$symbol':
                return is_string($inner) ? $inner : null;
            case '$undefined':
                return 'undefined';
        }
        return null;
    }

    private static function emit(array $documents, string $operation, float $elapsed, ?string $connection): void
    {
        $columns = [];
        foreach ($documents as $document) { foreach (array_keys($document) as $key) { $columns[$key] = true; } }
        $columns = array_slice(array_keys($columns), 0, 200);
        $rows = [];
        foreach ($documents as $document) {
            $row = [];
            foreach ($columns as $column) {
                $row[] = self::cell($document[$column] ?? null);
            }
            $rows[] = $row;
        }
        Channel::emit('sql', ['columns' => $columns, 'rows' => $rows, 'rowCount' => count($rows), 'driver' => 'mongodb', 'connection' => self::$definition['name'] ?? $connection, 'saved' => self::$definition !== null, 'source' => 'MongoDB ' . $operation, 'elapsedMs' => $elapsed, 'truncated' => false]);
        Runner::emitDump($documents, 'MongoDB documents · Extended JSON');
    }

    // MARK: Stop cancels on the server (#207), like SQL tabs (#144)

    /**
     * The tag the run's operations carry as their `comment`: `runlet:<run id>`. MongoDB 4.4 and
     * later accept `comment` on every command; older servers get no tag (Stop ends the runner only).
     */
    private static function tag(\MongoDB\Driver\Server $server): ?string
    {
        $runId = strtolower(Runner::runId());
        if (!preg_match('/^[0-9a-f-]{36}$/D', $runId) || (int) ($server->getInfo()['maxWireVersion'] ?? 0) < 9) { return null; }
        return 'runlet:' . $runId;
    }

    /**
     * What identifies the server process an operation runs on: its `topologyVersion.processId`
     * (MongoDB 4.4 and later, unique per process), or its host and port. Hashed, like SQL's (#144).
     */
    private static function fingerprint(\MongoDB\Driver\Server $server): string
    {
        $info = $server->getInfo();
        $topology = $info['topologyVersion'] ?? null;
        $process = is_array($topology) ? ($topology['processId'] ?? null) : (is_object($topology) ? ($topology->processId ?? null) : null);
        $id = $process instanceof \MongoDB\BSON\ObjectId ? 'process:' . (string) $process : 'address:' . $server->getHost() . ':' . $server->getPort();
        return substr(hash('sha256', 'mongodb|' . $id), 0, 16);
    }

    /** The `sqlSession` event (#144, #180): the tag and the server, never credentials. */
    private static function reportSession(\MongoDB\Driver\Server $server, string $tag, ?string $connection): void
    {
        Channel::emit('sqlSession', array_filter([
            'driver' => 'mongodb',
            'id' => 0,
            'tag' => $tag,
            'connection' => self::$definition === null ? $connection : null,
            'saved' => self::$definition === null ? null : true,
            'server' => self::fingerprint($server),
        ], static function ($value): bool {
            return $value !== null;
        }));
    }

    /** The connection's server with `$fingerprint`, after the driver discovered them; null when none has it. */
    private static function serverWithFingerprint(\MongoDB\Driver\Manager $manager, string $fingerprint): ?\MongoDB\Driver\Server
    {
        $manager->selectServer(new \MongoDB\Driver\ReadPreference('primaryPreferred'));
        foreach ($manager->getServers() as $server) {
            if (self::fingerprint($server) === $fingerprint) { return $server; }
        }
        return null;
    }

    /** The users this connection is authenticated as, as `user@db` (empty without authentication). */
    private static function authenticatedUsers(\MongoDB\Driver\Server $server): array
    {
        $status = $server->executeCommand('admin', new \MongoDB\Driver\Command(['connectionStatus' => 1]))->toArray()[0] ?? null;
        $users = [];
        foreach (($status->authInfo->authenticatedUsers ?? []) as $user) { $users[] = $user->user . '@' . $user->db; }
        sort($users);
        return $users;
    }

    /** An operation's effective users, as `user@db`, sorted. */
    private static function operationUsers($op): array
    {
        $users = [];
        foreach (($op->effectiveUsers ?? []) as $user) { $users[] = $user->user . '@' . $user->db; }
        sort($users);
        return $users;
    }

    /** This user's operations on `$server` that carry `$tag` (a getMore carries it in its originating command). */
    private static function taggedOperations(\MongoDB\Driver\Server $server, string $tag): array
    {
        $result = $server->executeCommand('admin', new \MongoDB\Driver\Command([
            'currentOp' => 1, '$ownOps' => true,
            '$or' => [['command.comment' => $tag], ['originatingCommand.comment' => $tag]],
        ]))->toArray()[0] ?? null;
        return is_object($result) && is_array($result->inprog ?? null) ? $result->inprog : [];
    }

    /**
     * Stop's second runner (#207): opens the same connection, checks it reached the server the run
     * reported (`$fingerprint`), finds this user's operations tagged `$tag` with `currentOp`,
     * refuses another user's, sends `killOp` for each, and watches them end. Emits `sqlCancel`.
     */
    public static function cancel(string $tag, ?string $connection, string $fingerprint): NoResult
    {
        $started = hrtime(true);
        $report = static function (string $outcome, array $fields = []) use ($started): NoResult {
            Channel::emit('sqlCancel', array_filter([
                'outcome' => $outcome, 'driver' => 'mongodb', 'session' => 0,
                'statement' => $fields['statement'] ?? 'killOp',
                'detail' => $fields['detail'] ?? null,
                'state' => $fields['state'] ?? null,
                'verified' => $fields['verified'] ?? null,
                'elapsedMs' => round((hrtime(true) - $started) / 1e6, 3),
            ], static function ($value): bool {
                return $value !== null;
            }));
            return NoResult::instance();
        };
        if (!preg_match('/^runlet:[0-9a-f-]{36}$/D', $tag)) { return $report('refused', ['detail' => 'Runlet kills only operations it tagged itself']); }
        if (!extension_loaded('mongodb')) { return $report('failed', ['detail' => 'this PHP has no ext-mongodb']); }
        try {
            [$manager] = self::connect($connection);
            $server = self::serverWithFingerprint($manager, $fingerprint);
            if ($server === null) {
                return $report('refused', ['detail' => 'the second connection reached another MongoDB server than the run (a list of hosts, a failover, or a load balancer?), so Runlet sent nothing there']);
            }
            $users = self::authenticatedUsers($server);
            $operations = self::taggedOperations($server, $tag);
            if ($operations === []) { return $report('idle'); }
            $ids = [];
            foreach ($operations as $operation) {
                if (self::operationUsers($operation) !== $users) {
                    return $report('refused', ['detail' => 'operation ' . self::opText($operation->opid ?? '?') . ' runs as another MongoDB user']);
                }
                $ids[] = $operation->opid;
            }
            foreach ($ids as $id) {
                $server->executeCommand('admin', new \MongoDB\Driver\Command(['killOp' => 1, 'op' => $id]));
            }
            $statement = 'killOp ' . implode(', ', array_map([self::class, 'opText'], $ids));
            $deadline = hrtime(true) + 2000 * 1000000;
            do {
                usleep(100000);
                $left = self::taggedOperations($server, $tag);
                if ($left === []) { return $report('cancelled', ['statement' => $statement, 'verified' => true]); }
            } while (hrtime(true) < $deadline);
            return $report('stillRunning', ['statement' => $statement, 'state' => ($left[0]->desc ?? null)]);
        } catch (\Throwable $error) {
            return $report($error->getCode() === 13 ? 'refused' : 'failed', ['detail' => $error->getCode() === 13 ? 'this MongoDB user may not list or kill the operation (code 13)' : 'MongoDB answered with code ' . (int) $error->getCode()]);
        }
    }

    /** An opid as text: 4711, or "shard01:4711" on mongos. */
    private static function opText($id): string
    {
        return is_int($id) ? (string) $id : (is_string($id) ? $id : (string) json_encode($id));
    }

    // MARK: The Database pane's Server section (#207), like SQL's (#150) and Redis's

    /**
     * Reads the server the tab's reads go to: a `serverStatus` summary (version, uptime,
     * connections, memory, replica set state) and `currentOp`'s operations, tagged with the
     * panel's own comment so the list can name its own operation. Emits `mongoServer`. Changes
     * nothing; a part the user may not read reports why.
     */
    public static function server(?string $connection): NoResult
    {
        ini_set('zend.exception_ignore_args', '1');
        try {
            [$manager] = self::connect($connection);
            $server = $manager->selectServer($manager->getReadPreference());
        } catch (\Throwable $error) {
            if (!extension_loaded('mongodb') || $error instanceof \RuntimeException && !$error instanceof \MongoDB\Driver\Exception\Exception) { throw $error; }
            throw new \RuntimeException('MongoDB connection failed. Check the host, authentication and TLS settings. Driver code: ' . (int) $error->getCode());
        }
        $own = 'runlet:' . strtolower(Runner::runId()) . ':panel';
        $report = ['server' => self::fingerprint($server), 'host' => $server->getHost() . ':' . $server->getPort(), 'listedBy' => $own, 'errors' => []];
        $info = $server->getInfo();
        $report['replica'] = array_filter([
            'setName' => is_string($info['setName'] ?? null) ? $info['setName'] : null,
            'state' => isset($info['setName']) ? (($info['isWritablePrimary'] ?? $info['ismaster'] ?? false) ? 'PRIMARY' : (($info['secondary'] ?? false) ? 'SECONDARY' : (($info['arbiterOnly'] ?? false) ? 'ARBITER' : 'OTHER'))) : null,
            'primary' => is_string($info['primary'] ?? null) ? $info['primary'] : null,
            'me' => is_string($info['me'] ?? null) ? $info['me'] : null,
            'mongos' => ($info['msg'] ?? '') === 'isdbgrid' ? true : null,
        ], static function ($value): bool { return $value !== null; });
        try {
            $status = $server->executeCommand('admin', new \MongoDB\Driver\Command(['serverStatus' => 1, 'repl' => 1, 'metrics' => 0, 'locks' => 0, 'wiredTiger' => 0, 'tcmalloc' => 0]))->toArray()[0];
            $report['status'] = array_filter([
                'version' => is_string($status->version ?? null) ? $status->version : null,
                'process' => is_string($status->process ?? null) ? $status->process : null,
                'host' => is_string($status->host ?? null) ? $status->host : null,
                'uptime' => isset($status->uptime) ? (int) $status->uptime : null,
                'connections' => isset($status->connections) ? array_filter(['current' => (int) ($status->connections->current ?? 0), 'available' => (int) ($status->connections->available ?? 0), 'totalCreated' => (int) ($status->connections->totalCreated ?? 0)], static function ($value) { return true; }) : null,
                'memory' => isset($status->mem) ? ['residentMB' => (int) ($status->mem->resident ?? 0), 'virtualMB' => (int) ($status->mem->virtual ?? 0)] : null,
                'storageEngine' => is_string($status->storageEngine->name ?? null) ? $status->storageEngine->name : null,
                'replicaState' => isset($status->repl->setName) ? (($status->repl->isWritablePrimary ?? $status->repl->ismaster ?? false) ? 'PRIMARY' : (($status->repl->secondary ?? false) ? 'SECONDARY' : 'OTHER')) : null,
                'opcounters' => isset($status->opcounters) ? array_map('intval', (array) $status->opcounters) : null,
            ], static function ($value): bool { return $value !== null; });
        } catch (\Throwable $error) {
            $report['errors']['serverStatus'] = self::panelError($error);
        }
        try {
            [$inprog, $report['ownOnly']] = self::currentOperations($server, [], $own);
            $operations = [];
            foreach ($inprog as $op) {
                if (count($operations) >= 200) { break; }
                $comment = is_string($op->command->comment ?? null) ? $op->command->comment : null;
                $operations[] = array_filter([
                    'opid' => self::opText($op->opid ?? ''),
                    'numeric' => is_int($op->opid ?? null) ? true : null,
                    'op' => is_string($op->op ?? null) ? $op->op : null,
                    'ns' => is_string($op->ns ?? null) && $op->ns !== '' ? $op->ns : null,
                    'desc' => is_string($op->desc ?? null) ? $op->desc : null,
                    'client' => is_string($op->client ?? null) ? $op->client : (is_string($op->client_s ?? null) ? $op->client_s : null),
                    'appName' => is_string($op->appName ?? null) ? self::clean($op->appName) : null,
                    'users' => self::operationUsers($op) ?: null,
                    'active' => isset($op->active) ? (bool) $op->active : null,
                    'micros' => isset($op->microsecs_running) ? (int) $op->microsecs_running : null,
                    'waitingForLock' => !empty($op->waitingForLock) ? true : null,
                    'comment' => $comment === null ? null : self::clean($comment),
                    'command' => isset($op->command) ? self::commandSummary($op->command) : null,
                    'own' => $comment === $own ? true : null,
                ], static function ($value): bool { return $value !== null; });
            }
            $report['operations'] = $operations;
        } catch (\Throwable $error) {
            $report['errors']['currentOp'] = self::panelError($error);
        }
        foreach (['errors', 'replica', 'status'] as $key) {
            if (($report[$key] ?? null) === []) { unset($report[$key]); }
        }
        if (isset($report['status']['opcounters']) && $report['status']['opcounters'] === []) { unset($report['status']['opcounters']); }
        Channel::emit('mongoServer', $report);
        return NoResult::instance();
    }

    /**
     * `$currentOp` (active operations, at most 200) matching `$match`, as the panel lists them:
     * every user's, or only this user's when it lacks the inprog privilege (then the second
     * value is true). The aggregate carries `$comment`, so the list can name the panel's own.
     */
    private static function currentOperations(\MongoDB\Driver\Server $server, array $match, ?string $comment): array
    {
        foreach ([true, false] as $allUsers) {
            $pipeline = [['$currentOp' => ['allUsers' => $allUsers, 'idleConnections' => false]]];
            if ($match !== []) { $pipeline[] = ['$match' => $match]; }
            $pipeline[] = ['$limit' => 200];
            try {
                $cursor = $server->executeReadCommand('admin', new \MongoDB\Driver\Command(['aggregate' => 1, 'pipeline' => $pipeline, 'cursor' => new \stdClass()] + ($comment === null ? [] : ['comment' => $comment])));
                return [$cursor->toArray(), !$allUsers];
            } catch (\MongoDB\Driver\Exception\Exception $denied) {
                // Without the inprog privilege, a user may list (and kill) only their own operations.
                if ($denied->getCode() !== 13 || !$allUsers) { throw $denied; }
            }
        }
        return [[], true];
    }

    /** "find shop.orders { filter: { status: "paid" }, limit: 50 }": the command, shortened, without session fields. */
    private static function commandSummary($command): string
    {
        $fields = [];
        foreach ((array) $command as $key => $value) {
            if ($key === 'lsid' || $key === 'comment' || (is_string($key) && $key !== '' && $key[0] === '$')) { continue; }
            $fields[$key] = $value;
        }
        $json = json_encode($fields, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR);
        $text = self::clean(is_string($json) ? $json : '');
        return strlen($text) > 400 ? substr($text, 0, 400) . '…' : $text;
    }

    private static function panelError(\Throwable $error): string
    {
        $code = (int) $error->getCode();
        return $code === 13 ? 'This MongoDB user isn\'t allowed to read it (code 13, Unauthorized).' : 'MongoDB refused it (code ' . $code . ').';
    }

    /**
     * Kill Op, confirmed in the app (#207): refuses another server (`$fingerprint`), the panel's
     * own operation and this runner's, and an operation that isn't the one listed any more (its
     * namespace or kind changed, or it's gone); then `killOp`. Emits `mongoKill`.
     */
    public static function killOp($opid, string $fingerprint, string $listedBy, string $ns, string $op, ?string $connection): NoResult
    {
        $report = static function (string $outcome, string $detail) use ($opid): NoResult {
            Channel::emit('mongoKill', ['opid' => self::opText($opid), 'outcome' => $outcome, 'detail' => $detail]);
            return NoResult::instance();
        };
        $text = self::opText($opid);
        try {
            [$manager] = self::connect($connection);
            $server = self::serverWithFingerprint($manager, $fingerprint);
            if ($server === null) {
                return $report('refused', 'This connection reached another MongoDB server than the one the list came from, so Runlet killed nothing. Read the operations again.');
            }
            $current = self::currentOperations($server, ['opid' => $opid], null)[0][0] ?? null;
            if ($current === null) { return $report('gone', 'Operation ' . $text . ' isn\'t running any more.'); }
            $comment = is_string($current->command->comment ?? null) ? $current->command->comment : '';
            if ($comment === $listedBy || strpos($comment, 'runlet:' . strtolower(Runner::runId())) === 0) {
                return $report('refused', 'Operation ' . $text . ' is Runlet\'s own, so it wasn\'t killed.');
            }
            if ((string) ($current->ns ?? '') !== $ns || (string) ($current->op ?? '') !== $op) {
                return $report('refused', 'Operation ' . $text . ' is now ' . (string) ($current->op ?? '?') . ' on ' . ((string) ($current->ns ?? '') ?: 'no namespace') . ', not the one listed, so Runlet killed nothing. Read the operations again.');
            }
            $server->executeCommand('admin', new \MongoDB\Driver\Command(['killOp' => 1, 'op' => $opid]));
            return $report('killed', 'Killed operation ' . $text . ' (killOp). It ends at its next interruption point.');
        } catch (\Throwable $error) {
            if ($error instanceof \RuntimeException && !$error instanceof \MongoDB\Driver\Exception\Exception) { return $report('failed', $error->getMessage()); }
            return $report('failed', (int) $error->getCode() === 13 ? 'This MongoDB user may not kill operation ' . $text . ' (code 13, Unauthorized).' : 'MongoDB refused killOp (code ' . (int) $error->getCode() . ').');
        }
    }

    public static function test(): NoResult
    {
        try {
            [$manager, $database] = self::connect(null);
            $manager->executeCommand('admin', new \MongoDB\Driver\Command(['ping' => 1]));
            Channel::emit('sqlTest', ['driver' => 'mongodb', 'serverVersion' => 'MongoDB', 'database' => $database, 'elapsedMs' => 0]);
        } catch (\Throwable $error) {
            if (!extension_loaded('mongodb')) { throw $error; }
            throw new \RuntimeException('MongoDB connection test failed. Check the host, authentication and TLS settings.');
        }
        return NoResult::instance();
    }
}
