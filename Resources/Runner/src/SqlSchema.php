<?php

declare(strict_types=1);

/*
 * SQL tabs' schema (#128, #21): the tables and columns of a connection for completion and the
 * schema explorer, with their kind (table or view), approximate row counts, column details
 * (nullable, default, primary key, foreign key), and indexes. Only the database's catalog is
 * read, never rows. SqlTab resolves the connection and emits the `sqlSchema` event.
 *
 * Per database, one catalog query for the columns (a detailed one, else the plain one from
 * #128), then one for indexes and one for foreign keys. Those two are extras: when one fails,
 * the schema still has its tables and columns, and a note says what is missing.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class SqlSchema
{
    /** Tables and columns reported at most, and the longest name kept. */
    public const MAX_TABLES = 2000;
    public const MAX_COLUMNS = 50000;
    /** Index columns reported at most (all tables together). */
    public const MAX_INDEX_COLUMNS = 20000;
    public const MAX_NAME_BYTES = 200;
    /** Bytes of a column default kept. */
    private const MAX_DEFAULT_BYTES = 200;

    /**
     * The driver's sqlSchema(), else the connection's own catalog.
     *
     * @param \PDO|callable $source
     * @return array<string, mixed> `tables`, `how`, and `truncated`/`notes` when they apply
     */
    public static function read(?string $connection, $source, string $origin, ?string $driverName): array
    {
        $driver = Runner::bootedDriver();
        if ($driver !== null) {
            $declared = Runner::callBootedDriver('sqlSchema()', static function () use ($driver, $connection) {
                return $driver->sqlSchema($connection);
            });
            if (is_array($declared)) {
                $declaring = (new \ReflectionMethod($driver, 'sqlSchema'))->getDeclaringClass()->getName();

                return self::declared($declared) + ['how' => $declaring . '::sqlSchema()'];
            }
        }
        $dialects = self::dialects($source, $origin, $driverName);
        if ($dialects === []) {
            throw new \RuntimeException('Runlet doesn\'t know how to list the tables of ' . ($driverName ?? 'this') . ' connections. Return them from sqlSchema() in a project driver.');
        }
        $failure = null;
        foreach ($dialects as $dialect) {
            $queries = self::queries($dialect);
            $rows = null;
            foreach ([$queries['columns'], $queries['plainColumns']] as $sql) {
                try {
                    $rows = self::fetch($source, $sql, self::MAX_COLUMNS + 1);
                    break;
                } catch (\Throwable $error) {
                    $failure = $failure ?? $error;
                }
            }
            if ($rows === null) {
                continue;
            }
            $builder = new SchemaBuilder();
            $builder->addColumns($rows);
            foreach (['indexes' => 'Indexes', 'foreignKeys' => 'Foreign keys'] as $kind => $label) {
                if (!isset($queries[$kind])) {
                    continue;
                }
                try {
                    $extra = self::fetch($source, $queries[$kind], self::MAX_INDEX_COLUMNS + 1);
                    $kind === 'indexes' ? $builder->addIndexes($extra) : $builder->addForeignKeys($extra);
                } catch (\Throwable $error) {
                    $builder->note($label . ' could not be read: ' . $error->getMessage());
                }
            }

            return $builder->result() + ['how' => $queries['how']];
        }
        throw new \RuntimeException(($failure !== null ? $failure->getMessage() : 'no tables') . ' Return the schema from sqlSchema() in a project driver if this connection can\'t list its tables.');
    }

    /**
     * The catalogs to try: the PDO driver's, or for a callable (its dialect unknown) each in
     * turn ($wpdb is MySQL).
     *
     * @param \PDO|callable $source
     * @return string[]
     */
    private static function dialects($source, string $origin, ?string $driverName): array
    {
        switch ($driverName) {
            case 'sqlite':
            case 'mysql':
            case 'pgsql':
                return [$driverName];
            case 'sqlsrv':
            case 'dblib':
                return ['sqlsrv'];
        }
        if ($source instanceof \PDO) {
            return [];
        }

        return $origin === 'WordPress $wpdb' ? ['mysql', 'sqlite'] : ['mysql', 'pgsql', 'sqlite'];
    }

    /**
     * One dialect's catalog queries. Columns rows: table, column, type, nullable, default,
     * primary key, kind (`table` or `view`), approximate rows. Index rows: table, index,
     * unique, primary, column. Foreign key rows: table, column, referenced table, referenced
     * column, and the constraint they belong to (#153: a composite key's columns share it).
     * Columns have distinct names: callables may return associative rows.
     *
     * @return array<string, string>
     */
    private static function queries(string $dialect): array
    {
        switch ($dialect) {
            case 'sqlite':
                return [
                    'how' => 'sqlite_master',
                    'columns' => <<<'SQL'
                        SELECT m.name AS table_name, p.name AS column_name, p.type AS data_type,
                            CASE WHEN p."notnull" = 0 AND p.pk = 0 THEN 1 ELSE 0 END AS nullable, p.dflt_value AS column_default,
                            CASE WHEN p.pk > 0 THEN 1 ELSE 0 END AS primary_key, m.type AS table_kind, NULL AS approx_rows
                        FROM sqlite_master m JOIN pragma_table_info(m.name) p
                        WHERE m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite\_%' ESCAPE '\'
                        ORDER BY m.name, p.cid
                        SQL,
                    'plainColumns' => <<<'SQL'
                        SELECT m.name AS table_name, p.name AS column_name, p.type AS data_type
                        FROM sqlite_master m JOIN pragma_table_info(m.name) p
                        WHERE m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite\_%' ESCAPE '\'
                        ORDER BY m.name, p.cid
                        SQL,
                    'indexes' => <<<'SQL'
                        SELECT m.name AS table_name, il.name AS index_name, il."unique" AS is_unique,
                            CASE WHEN il.origin = 'pk' THEN 1 ELSE 0 END AS is_primary, ii.name AS column_name
                        FROM sqlite_master m JOIN pragma_index_list(m.name) il JOIN pragma_index_info(il.name) ii
                        WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\_%' ESCAPE '\'
                        ORDER BY m.name, il.name, ii.seqno
                        SQL,
                    'foreignKeys' => <<<'SQL'
                        SELECT m.name AS table_name, fk."from" AS column_name, fk."table" AS referenced_table, fk."to" AS referenced_column,
                            fk.id AS constraint_name
                        FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) fk
                        WHERE m.type = 'table'
                        ORDER BY m.name, fk.id, fk.seq
                        SQL,
                ];
            case 'mysql':
                return [
                    'how' => 'information_schema',
                    'columns' => <<<'SQL'
                        SELECT c.TABLE_NAME AS table_name, c.COLUMN_NAME AS column_name, c.DATA_TYPE AS data_type,
                            CASE WHEN c.IS_NULLABLE = 'YES' THEN 1 ELSE 0 END AS nullable, c.COLUMN_DEFAULT AS column_default,
                            CASE WHEN c.COLUMN_KEY = 'PRI' THEN 1 ELSE 0 END AS primary_key,
                            CASE WHEN t.TABLE_TYPE = 'VIEW' THEN 'view' ELSE 'table' END AS table_kind, t.TABLE_ROWS AS approx_rows
                        FROM information_schema.COLUMNS c
                        JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
                        WHERE c.TABLE_SCHEMA = DATABASE()
                        ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
                        SQL,
                    'plainColumns' => <<<'SQL'
                        SELECT TABLE_NAME AS table_name, COLUMN_NAME AS column_name, DATA_TYPE AS data_type
                        FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION
                        SQL,
                    'indexes' => <<<'SQL'
                        SELECT TABLE_NAME AS table_name, INDEX_NAME AS index_name, CASE WHEN NON_UNIQUE = 0 THEN 1 ELSE 0 END AS is_unique,
                            CASE WHEN INDEX_NAME = 'PRIMARY' THEN 1 ELSE 0 END AS is_primary, COLUMN_NAME AS column_name
                        FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE()
                        ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
                        SQL,
                    'foreignKeys' => <<<'SQL'
                        SELECT TABLE_NAME AS table_name, COLUMN_NAME AS column_name,
                            CASE WHEN REFERENCED_TABLE_SCHEMA = DATABASE() THEN REFERENCED_TABLE_NAME ELSE CONCAT(REFERENCED_TABLE_SCHEMA, '.', REFERENCED_TABLE_NAME) END AS referenced_table,
                            REFERENCED_COLUMN_NAME AS referenced_column, CONSTRAINT_NAME AS constraint_name
                        FROM information_schema.KEY_COLUMN_USAGE
                        WHERE TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL
                        ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
                        SQL,
                ];
            case 'pgsql':
                return [
                    'how' => 'information_schema',
                    'columns' => <<<'SQL'
                        SELECT CASE WHEN c.table_schema = current_schema() THEN c.table_name ELSE c.table_schema || '.' || c.table_name END AS table_name,
                            c.column_name AS column_name, c.data_type AS data_type,
                            CASE WHEN c.is_nullable = 'YES' THEN 1 ELSE 0 END AS nullable, c.column_default AS column_default,
                            CASE WHEN EXISTS (
                                SELECT 1 FROM pg_catalog.pg_constraint pc
                                JOIN pg_catalog.pg_class pt ON pt.oid = pc.conrelid
                                JOIN pg_catalog.pg_namespace pn ON pn.oid = pt.relnamespace
                                JOIN pg_catalog.pg_attribute pa ON pa.attrelid = pc.conrelid AND pa.attnum = ANY (pc.conkey)
                                WHERE pc.contype = 'p' AND pn.nspname = c.table_schema AND pt.relname = c.table_name AND pa.attname = c.column_name
                            ) THEN 1 ELSE 0 END AS primary_key,
                            CASE WHEN t.table_type = 'VIEW' THEN 'view' ELSE 'table' END AS table_kind,
                            (SELECT CASE WHEN cl.reltuples < 0 THEN NULL ELSE cl.reltuples::bigint END
                                FROM pg_catalog.pg_class cl JOIN pg_catalog.pg_namespace n ON n.oid = cl.relnamespace
                                WHERE n.nspname = c.table_schema AND cl.relname = c.table_name) AS approx_rows
                        FROM information_schema.columns c
                        JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
                        WHERE c.table_schema = ANY (current_schemas(false))
                        ORDER BY 1, c.ordinal_position
                        SQL,
                    'plainColumns' => <<<'SQL'
                        SELECT CASE WHEN c.table_schema = current_schema() THEN c.table_name ELSE c.table_schema || '.' || c.table_name END AS table_name,
                            c.column_name AS column_name, c.data_type AS data_type
                        FROM information_schema.columns c WHERE c.table_schema = ANY (current_schemas(false)) ORDER BY 1, c.ordinal_position
                        SQL,
                    'indexes' => <<<'SQL'
                        SELECT CASE WHEN n.nspname = current_schema() THEN t.relname ELSE n.nspname || '.' || t.relname END AS table_name,
                            i.relname AS index_name, CASE WHEN ix.indisunique THEN 1 ELSE 0 END AS is_unique,
                            CASE WHEN ix.indisprimary THEN 1 ELSE 0 END AS is_primary, a.attname AS column_name
                        FROM pg_catalog.pg_index ix
                        JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
                        JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
                        JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
                        CROSS JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord)
                        LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
                        WHERE n.nspname = ANY (current_schemas(false))
                        ORDER BY 1, 2, k.ord
                        SQL,
                    'foreignKeys' => <<<'SQL'
                        SELECT CASE WHEN n.nspname = current_schema() THEN t.relname ELSE n.nspname || '.' || t.relname END AS table_name,
                            a.attname AS column_name,
                            CASE WHEN rn.nspname = current_schema() THEN rt.relname ELSE rn.nspname || '.' || rt.relname END AS referenced_table,
                            ra.attname AS referenced_column, c.conname AS constraint_name
                        FROM pg_catalog.pg_constraint c
                        JOIN pg_catalog.pg_class t ON t.oid = c.conrelid
                        JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
                        JOIN pg_catalog.pg_class rt ON rt.oid = c.confrelid
                        JOIN pg_catalog.pg_namespace rn ON rn.oid = rt.relnamespace
                        CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS k(col, refcol, ord)
                        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.col
                        JOIN pg_catalog.pg_attribute ra ON ra.attrelid = c.confrelid AND ra.attnum = k.refcol
                        WHERE c.contype = 'f' AND n.nspname = ANY (current_schemas(false))
                        ORDER BY 1, c.conname, k.ord
                        SQL,
                ];
            default: // sqlsrv: columns with their details; indexes and foreign keys are not read.
                return [
                    'how' => 'INFORMATION_SCHEMA',
                    'columns' => <<<'SQL'
                        SELECT CASE WHEN c.TABLE_SCHEMA = SCHEMA_NAME() THEN c.TABLE_NAME ELSE c.TABLE_SCHEMA + '.' + c.TABLE_NAME END AS table_name,
                            c.COLUMN_NAME AS column_name, c.DATA_TYPE AS data_type,
                            CASE WHEN c.IS_NULLABLE = 'YES' THEN 1 ELSE 0 END AS nullable, c.COLUMN_DEFAULT AS column_default,
                            CASE WHEN EXISTS (
                                SELECT 1 FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE k ON k.CONSTRAINT_NAME = tc.CONSTRAINT_NAME AND k.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
                                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' AND tc.TABLE_SCHEMA = c.TABLE_SCHEMA AND tc.TABLE_NAME = c.TABLE_NAME AND k.COLUMN_NAME = c.COLUMN_NAME
                            ) THEN 1 ELSE 0 END AS primary_key,
                            CASE WHEN t.TABLE_TYPE = 'VIEW' THEN 'view' ELSE 'table' END AS table_kind, NULL AS approx_rows
                        FROM INFORMATION_SCHEMA.COLUMNS c
                        JOIN INFORMATION_SCHEMA.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
                        ORDER BY 1, c.ORDINAL_POSITION
                        SQL,
                    'plainColumns' => <<<'SQL'
                        SELECT CASE WHEN TABLE_SCHEMA = SCHEMA_NAME() THEN TABLE_NAME ELSE TABLE_SCHEMA + '.' + TABLE_NAME END AS table_name,
                            COLUMN_NAME AS column_name, DATA_TYPE AS data_type
                        FROM INFORMATION_SCHEMA.COLUMNS ORDER BY 1, ORDINAL_POSITION
                        SQL,
                ];
        }
    }

    /**
     * Rows of a catalog query as lists of values, at most `$limit`.
     *
     * @param \PDO|callable $source
     * @return array<int, array<int, mixed>>
     */
    private static function fetch($source, string $sql, int $limit): array
    {
        $rows = [];
        if ($source instanceof \PDO) {
            $source->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
            $statement = $source->query($sql);
            while (($row = $statement->fetch(\PDO::FETCH_NUM)) !== false) {
                $rows[] = $row;
                if (count($rows) >= $limit) {
                    break;
                }
            }
            $statement->closeCursor();

            return $rows;
        }
        $returned = $source($sql);
        if (!is_iterable($returned)) {
            throw new \UnexpectedValueException('the connection returned no rows for the catalog query');
        }
        foreach ($returned as $row) {
            $rows[] = array_values(is_object($row) ? get_object_vars($row) : (array) $row);
            if (count($rows) >= $limit) {
                break;
            }
        }

        return $rows;
    }

    /**
     * A driver's own schema: `table => [column => type]` or `table => [column, …]` (#128), or
     * per table `['columns' => [column => type or details], 'indexes' => [...], 'rows' => n,
     * 'kind' => 'view']` (#21). Column details: `type`, `nullable`, `default`, `primaryKey`,
     * `references` (`table.column`). Indexes: `name`, `columns`, `unique`, `primary`.
     *
     * @param array<mixed> $declared
     * @return array<string, mixed>
     */
    private static function declared(array $declared): array
    {
        $builder = new SchemaBuilder();
        $columnRows = [];
        $indexRows = [];
        $foreignKeys = [];
        foreach ($declared as $table => $spec) {
            $table = (string) $table;
            $detailed = is_array($spec) && isset($spec['columns']) && is_array($spec['columns']);
            $columns = $detailed ? $spec['columns'] : (is_array($spec) ? $spec : []);
            $kind = $detailed && ($spec['kind'] ?? null) === 'view' ? 'view' : 'table';
            $rows = $detailed && isset($spec['rows']) && is_numeric($spec['rows']) ? (int) $spec['rows'] : null;
            if ($columns === []) {
                $columnRows[] = [$table, null, null, null, null, null, $kind, $rows];
            }
            foreach ($columns as $key => $value) {
                if (is_int($key)) {
                    $columnRows[] = [$table, is_scalar($value) ? (string) $value : null, null, null, null, null, $kind, $rows];
                    continue;
                }
                if (!is_array($value)) {
                    $columnRows[] = [$table, (string) $key, is_scalar($value) ? (string) $value : null, null, null, null, $kind, $rows];
                    continue;
                }
                $columnRows[] = [
                    $table, (string) $key, isset($value['type']) && is_scalar($value['type']) ? (string) $value['type'] : null,
                    array_key_exists('nullable', $value) ? ($value['nullable'] ? 1 : 0) : null,
                    array_key_exists('default', $value) && is_scalar($value['default']) ? (string) $value['default'] : null,
                    !empty($value['primaryKey']) ? 1 : 0, $kind, $rows,
                ];
                if (isset($value['references']) && is_string($value['references']) && strpos($value['references'], '.') !== false) {
                    $at = (int) strrpos($value['references'], '.');
                    $foreignKeys[] = [$table, (string) $key, substr($value['references'], 0, $at), substr($value['references'], $at + 1)];
                }
            }
            foreach ($detailed && isset($spec['indexes']) && is_array($spec['indexes']) ? $spec['indexes'] : [] as $index) {
                if (!is_array($index) || !isset($index['name'], $index['columns']) || !is_array($index['columns'])) {
                    continue;
                }
                foreach ($index['columns'] as $column) {
                    $indexRows[] = [$table, (string) $index['name'], !empty($index['unique']) ? 1 : 0, !empty($index['primary']) ? 1 : 0, is_scalar($column) ? (string) $column : null];
                }
            }
        }
        $builder->addColumns($columnRows);
        $builder->addIndexes($indexRows);
        $builder->addForeignKeys($foreignKeys);

        return $builder->result();
    }

    /** A clean UTF-8 name within the limit, or null. */
    public static function name($value): ?string
    {
        if (!is_scalar($value)) {
            return null;
        }
        $name = (string) $value;

        return $name === '' || strlen($name) > self::MAX_NAME_BYTES || preg_match('//u', $name) !== 1 ? null : $name;
    }

    /** A column default as text, cut at a UTF-8 boundary; null when there is none. */
    public static function defaultValue($value): ?string
    {
        if ($value === null || !is_scalar($value)) {
            return null;
        }
        $text = (string) $value;
        if (preg_match('//u', $text) !== 1) {
            return null;
        }
        if (strlen($text) > self::MAX_DEFAULT_BYTES) {
            $text = substr($text, 0, self::MAX_DEFAULT_BYTES);
            while ($text !== '' && preg_match('//u', $text) !== 1) {
                $text = substr($text, 0, -1);
            }
            $text .= '…';
        }

        return $text;
    }

    /** 1, '1', true, 't', 'YES' → true; 0, '0', false, 'f', 'NO' → false; else null. */
    public static function flag($value): ?bool
    {
        if ($value === null) {
            return null;
        }
        if (is_bool($value)) {
            return $value;
        }
        $text = strtolower(trim((string) $value));
        if (in_array($text, ['1', 't', 'true', 'yes'], true)) {
            return true;
        }

        return in_array($text, ['0', 'f', 'false', 'no'], true) ? false : null;
    }
}

/** Builds the bounded `tables` list of an `sqlSchema` event from catalog rows. */
final class SchemaBuilder
{
    /** @var array<string, array<string, mixed>> */
    private $tables = [];
    /** @var array<string, array<string, int>> column positions per table */
    private $positions = [];
    private $columns = 0;
    private $indexColumns = 0;
    private $truncated = false;
    /** @var string[] */
    private $notes = [];

    /** @param array<int, array<int, mixed>> $rows table, column, type[, nullable, default, primary key, kind, rows] */
    public function addColumns(array $rows): void
    {
        foreach ($rows as $row) {
            $table = SqlSchema::name($row[0] ?? null);
            if ($table === null) {
                continue;
            }
            if (!isset($this->tables[$table])) {
                if (count($this->tables) >= SqlSchema::MAX_TABLES) {
                    $this->truncated = true;
                    continue;
                }
                $this->tables[$table] = ['name' => $table, 'columns' => []];
                $this->positions[$table] = [];
            }
            if (($row[6] ?? null) === 'view') {
                $this->tables[$table]['kind'] = 'view';
            }
            if (isset($row[7]) && is_numeric($row[7]) && (int) $row[7] >= 0) {
                $this->tables[$table]['rows'] = (int) $row[7];
            }
            $column = SqlSchema::name($row[1] ?? null);
            if ($column === null || isset($this->positions[$table][$column])) {
                continue;
            }
            if ($this->columns >= SqlSchema::MAX_COLUMNS) {
                $this->truncated = true;
                continue;
            }
            $entry = ['name' => $column];
            $type = isset($row[2]) && is_scalar($row[2]) ? strtolower(trim((string) $row[2])) : '';
            if ($type !== '' && strlen($type) <= 64 && preg_match('//u', $type) === 1) {
                $entry['type'] = $type;
            }
            $nullable = SqlSchema::flag($row[3] ?? null);
            if ($nullable !== null) {
                $entry['nullable'] = $nullable;
            }
            $default = SqlSchema::defaultValue($row[4] ?? null);
            if ($default !== null) {
                $entry['default'] = $default;
            }
            if (SqlSchema::flag($row[5] ?? null) === true) {
                $entry['primaryKey'] = true;
            }
            $this->positions[$table][$column] = count($this->tables[$table]['columns']);
            $this->tables[$table]['columns'][] = $entry;
            $this->columns++;
        }
    }

    /** @param array<int, array<int, mixed>> $rows table, index, unique, primary, column */
    public function addIndexes(array $rows): void
    {
        $order = [];
        foreach ($rows as $row) {
            $table = SqlSchema::name($row[0] ?? null);
            $index = SqlSchema::name($row[1] ?? null);
            $column = SqlSchema::name($row[4] ?? null);
            if ($table === null || $index === null || !isset($this->tables[$table])) {
                continue;
            }
            if ($this->indexColumns >= SqlSchema::MAX_INDEX_COLUMNS) {
                $this->truncated = true;
                break;
            }
            if (!isset($order[$table][$index])) {
                $order[$table][$index] = count($this->tables[$table]['indexes'] ?? []);
                $entry = ['name' => $index, 'columns' => []];
                if (SqlSchema::flag($row[2] ?? null) === true) {
                    $entry['unique'] = true;
                }
                if (SqlSchema::flag($row[3] ?? null) === true) {
                    $entry['primary'] = true;
                }
                $this->tables[$table]['indexes'][] = $entry;
            }
            if ($column !== null) {
                $this->tables[$table]['indexes'][$order[$table][$index]]['columns'][] = $column;
                $this->indexColumns++;
            }
        }
    }

    /**
     * Each column's `references`, and (#153) when the catalog names the constraint, the table's
     * `foreignKeys`: one entry per constraint with its columns in order, so a composite key is
     * one relation. `referencedColumns` is left out when the catalog doesn't name them (SQLite's
     * `REFERENCES customers`: the referenced table's primary key).
     *
     * @param array<int, array<int, mixed>> $rows table, column, referenced table, referenced column[, constraint]
     */
    public function addForeignKeys(array $rows): void
    {
        $order = [];
        foreach ($rows as $row) {
            $table = SqlSchema::name($row[0] ?? null);
            $column = SqlSchema::name($row[1] ?? null);
            $referenced = SqlSchema::name($row[2] ?? null);
            if ($table === null || $column === null || $referenced === null || !isset($this->positions[$table][$column])) {
                continue;
            }
            $target = SqlSchema::name($row[3] ?? null);
            $this->tables[$table]['columns'][$this->positions[$table][$column]]['references'] = $target === null ? $referenced : $referenced . '.' . $target;
            $constraint = SqlSchema::name($row[4] ?? null);
            if ($constraint === null) {
                continue;
            }
            $key = $constraint . "\x1F" . $referenced;
            if (!isset($order[$table][$key])) {
                $order[$table][$key] = count($this->tables[$table]['foreignKeys'] ?? []);
                $this->tables[$table]['foreignKeys'][] = ['name' => $constraint, 'columns' => [], 'references' => $referenced, 'referencedColumns' => []];
            }
            $at = $order[$table][$key];
            $this->tables[$table]['foreignKeys'][$at]['columns'][] = $column;
            if ($target === null || !isset($this->tables[$table]['foreignKeys'][$at]['referencedColumns'])) {
                unset($this->tables[$table]['foreignKeys'][$at]['referencedColumns']);
            } else {
                $this->tables[$table]['foreignKeys'][$at]['referencedColumns'][] = $target;
            }
        }
    }

    public function note(string $note): void
    {
        $this->notes[] = $note;
    }

    /** @return array<string, mixed> */
    public function result(): array
    {
        $result = ['tables' => array_values($this->tables)];
        if ($this->truncated) {
            $result['truncated'] = true;
        }
        if ($this->notes !== []) {
            $result['notes'] = $this->notes;
        }

        return $result;
    }
}
