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
        ];
        $operation = $query->operation ?? '';
        if (!is_string($operation) || !isset($fields[$operation])) { throw new \RuntimeException('Unsupported MongoDB operation.'); }
        if (array_diff(array_keys(get_object_vars($query)), array_merge(['collection', 'operation'], $fields[$operation]))) { throw new \RuntimeException('Unknown fields for this MongoDB operation.'); }
        $collection = $query->collection ?? '';
        if (!is_string($collection) || $collection === '' || strlen($collection) > 120 || strpos($collection, "\0") !== false || strpos($collection, 'system.') === 0) { throw new \RuntimeException('Invalid collection name.'); }
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
        $destructive = $operation === 'drop' || (in_array($operation, ['deleteMany', 'updateMany'], true) && count(get_object_vars($query->filter ?? new \stdClass())) === 0);
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
            $query = class_exists('MongoDB\BSON\Document')
                ? \MongoDB\BSON\Document::fromJSON(json_encode($query))->toPHP()
                : \MongoDB\BSON\toPHP(\MongoDB\BSON\fromJSON(json_encode($query)));
            $size = max(1, min(1000, (int) ($request['pageSize'] ?? 100)));
            $offset = max(0, min(1000000, (int) ($request['offset'] ?? 0)));
            $started = microtime(true);
            $documents = self::execute($manager, $database, $query, $size, $offset);
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
            if (!extension_loaded('mongodb')) { throw $error; }
            throw new \RuntimeException('MongoDB ' . $query->operation . ' failed. Check the connection, permissions, and query shape. Driver code: ' . (int) $error->getCode());
        }
        return NoResult::instance();
    }

    private static function execute($manager, string $database, $query, int $size, int $offset)
    {
        $operation = $query->operation;
        $collection = $query->collection;
        $filter = $query->filter ?? new \stdClass();
        if ($operation === 'listDatabases') {
            $result = $manager->executeReadCommand('admin', new \MongoDB\Driver\Command(['listDatabases' => 1, 'nameOnly' => true, 'authorizedDatabases' => true]))->toArray();
            return array_slice($result[0]->databases ?? [], 0, $size);
        }
        if ($operation === 'listCollections') {
            $cursor = $manager->executeReadCommand($database, new \MongoDB\Driver\Command(['listCollections' => 1, 'nameOnly' => true, 'authorizedCollections' => true, 'cursor' => ['batchSize' => 100]]));
            $collections = [];
            foreach ($cursor as $item) {
                if (count($collections) >= 100) { break; }
                $count = null;
                try {
                    $stats = $manager->executeReadCommand($database, new \MongoDB\Driver\Command(['collStats' => $item->name, 'maxTimeMS' => 5000]))->toArray();
                    $count = $stats[0]->count ?? null;
                } catch (\Throwable $ignored) {}
                $collections[] = (object) ['name' => $item->name, 'type' => $item->type ?? 'collection', 'estimatedCount' => $count];
            }
            return $collections;
        }
        if ($operation === 'sampleSchema') {
            $cursor = $manager->executeReadCommand($database, new \MongoDB\Driver\Command(['aggregate' => $collection, 'pipeline' => [['$sample' => ['size' => 50]]], 'cursor' => new \stdClass(), 'maxTimeMS' => 10000]));
            $fields = [];
            foreach ($cursor as $document) {
                foreach ($document as $name => $value) {
                    $type = is_object($value) ? get_class($value) : gettype($value);
                    $fields[$name][$type] = true;
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
            foreach (['projection', 'sort'] as $key) { if (isset($query->$key)) { $options[$key] = $query->$key; } }
            if (!($query->explain ?? false)) { return $manager->executeQuery($database . '.' . $collection, new \MongoDB\Driver\Query($filter, $options)); }
            $command = ['explain' => ['find' => $collection, 'filter' => $filter] + $options, 'verbosity' => 'queryPlanner'];
        } elseif ($operation === 'aggregate' || $operation === 'countDocuments') {
            $pipeline = $operation === 'countDocuments' ? [(object) ['$match' => $filter], (object) ['$count' => 'count']] : $query->pipeline;
            if (!self::hasKey($pipeline, ['$out', '$merge'])) {
                if ($offset > 0) { $pipeline[] = (object) ['$skip' => $offset]; }
                $pipeline[] = (object) ['$limit' => $size];
            }
            $command = ['aggregate' => $collection, 'pipeline' => $pipeline, 'cursor' => new \stdClass(), 'maxTimeMS' => 25000];
            if ($query->explain ?? false) { $command = ['explain' => $command, 'verbosity' => 'queryPlanner']; }
        } elseif ($operation === 'distinct') {
            $result = $manager->executeReadCommand($database, new \MongoDB\Driver\Command(['distinct' => $collection, 'key' => $query->field, 'query' => $filter, 'maxTimeMS' => 25000]))->toArray();
            return array_map(static function ($value) { return (object) ['value' => $value]; }, array_slice($result[0]->values ?? [], $offset, $size));
        } elseif ($operation === 'getIndexes') {
            $command = ['listIndexes' => $collection, 'cursor' => new \stdClass()];
        } elseif ($operation === 'drop') {
            return $manager->executeWriteCommand($database, new \MongoDB\Driver\Command(['drop' => $collection]));
        } elseif ($operation === 'createIndex') {
            $command = ['createIndexes' => $collection, 'indexes' => [['key' => $query->keys, 'name' => 'runlet_' . substr(hash('sha256', json_encode($query->keys)), 0, 12), 'unique' => $query->unique ?? false]]];
            return $manager->executeWriteCommand($database, new \MongoDB\Driver\Command($command));
        } else {
            $bulk = new \MongoDB\Driver\BulkWrite();
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

    private static function emit(array $documents, string $operation, float $elapsed, ?string $connection): void
    {
        $columns = [];
        foreach ($documents as $document) { foreach (array_keys($document) as $key) { $columns[$key] = true; } }
        $columns = array_slice(array_keys($columns), 0, 200);
        $rows = [];
        foreach ($documents as $document) {
            $row = [];
            foreach ($columns as $column) {
                $value = $document[$column] ?? null;
                if (is_array($value) && count($value) === 1) {
                    foreach (['$numberInt', '$numberLong', '$numberDouble', '$numberDecimal'] as $type) {
                        if (isset($value[$type])) { $value = $value[$type]; break; }
                    }
                    if (is_array($value) && isset($value['$oid'])) { $value = 'ObjectId("' . $value['$oid'] . '")'; }
                }
                $row[] = is_array($value) ? json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) : $value;
            }
            $rows[] = $row;
        }
        Channel::emit('sql', ['columns' => $columns, 'rows' => $rows, 'rowCount' => count($rows), 'driver' => 'mongodb', 'connection' => self::$definition['name'] ?? $connection, 'saved' => self::$definition !== null, 'source' => 'MongoDB ' . $operation, 'elapsedMs' => $elapsed, 'truncated' => false]);
        Runner::emitDump($documents, 'MongoDB documents · Extended JSON');
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
