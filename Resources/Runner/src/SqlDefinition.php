<?php

declare(strict_types=1);

/*
 * Show Definition (#148): the definition (DDL) of one table or view, read from the database's
 * catalog for the schema explorer, which opens it in a new SQL tab that doesn't run. Only the
 * catalog is read, never rows, and nothing is created or changed. SqlTab resolves the
 * connection and emits the `sqlDefinition` event.
 *
 * Per database:
 *  - MySQL and MariaDB: SHOW CREATE TABLE / SHOW CREATE VIEW, plus SHOW CREATE TRIGGER for
 *    the table's triggers;
 *  - SQLite: the object's own `sql` in sqlite_master, plus its indexes and triggers;
 *  - PostgreSQL, which has no SHOW CREATE: a CREATE TABLE reconstructed from pg_catalog
 *    (columns with types, defaults, identity, collation, NOT NULL), pg_get_constraintdef(),
 *    pg_get_indexdef(), pg_get_triggerdef(), comments, and the enum types its columns use;
 *    pg_get_viewdef() for views. The event says it is reconstructed.
 * SQL Server and other drivers are not supported. A callable connection (whose database Runlet
 * doesn't know) is tried as MySQL, PostgreSQL, then SQLite, like the schema; when a project
 * driver's sqlSchema() describes it instead of a catalog, there is no definition to read.
 *
 * Names are bound as parameters on PDO; a callable can't bind, so they are written as quoted
 * literals for its dialect. Identifiers in SHOW statements are quoted.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

/** The table or view isn't in this catalog (the dialect was right, the name wasn't). */
final class SqlDefinitionNotFound extends \RuntimeException
{
}

final class SqlDefinition
{
    /** Bytes of DDL reported at most. */
    public const MAX_BYTES = 2097152;
    /** Triggers and indexes read at most per table. */
    public const MAX_TRIGGERS = 100;
    public const MAX_INDEXES = 500;
    /** Columns of one table read at most (PostgreSQL). */
    public const MAX_COLUMNS = 5000;

    /**
     * The definition of `$table`, a name as the schema explorer lists it.
     *
     * @param \PDO|callable $source
     * @return array<string, mixed> `table`, `dialect`, `kind`, `how`, `sql`, and `reconstructed`, `server`, `notes` when they apply
     */
    public static function read($source, string $origin, ?string $driverName, string $table): array
    {
        if ($table === '' || strlen($table) > SqlSchema::MAX_NAME_BYTES || preg_match('//u', $table) !== 1) {
            throw new \InvalidArgumentException('Show Definition needs the name of a table or view.');
        }
        $dialects = self::dialects($source, $origin, $driverName);
        $failure = null;
        foreach ($dialects as $dialect) {
            try {
                switch ($dialect) {
                    case 'mysql':
                        $result = self::mysql($source, $table);
                        break;
                    case 'pgsql':
                        $result = self::pgsql($source, $table);
                        break;
                    default:
                        $result = self::sqlite($source, $table);
                }
            } catch (SqlDefinitionNotFound $missing) {
                throw $missing;
            } catch (DriverFailure $driverFailure) {
                throw $driverFailure;
            } catch (\Throwable $error) {
                $failure = $failure ?? $error;
                continue;
            }
            $server = $source instanceof \PDO ? self::server($source, $dialect) : null;
            if ($server !== null) {
                $result['server'] = $server;
            }
            $result['sql'] = self::bounded($result['sql'], $result);

            return ['table' => $table, 'dialect' => $dialect] + $result;
        }
        throw new \RuntimeException($failure !== null ? $failure->getMessage() : 'no catalog answered');
    }

    /**
     * The catalogs to try: the PDO driver's, or for a callable each in turn ($wpdb is MySQL).
     *
     * @param \PDO|callable $source
     * @return string[]
     */
    private static function dialects($source, string $origin, ?string $driverName): array
    {
        switch ($driverName) {
            case 'mysql':
            case 'pgsql':
            case 'sqlite':
                return [$driverName];
            case 'sqlsrv':
            case 'dblib':
                throw new SqlUnavailable('Runlet doesn\'t show SQL Server definitions yet. Use your database tool, or sp_helptext and the sys catalog views, to read this one.');
        }
        if ($source instanceof \PDO) {
            throw new SqlUnavailable('Runlet can\'t show definitions on ' . ($driverName ?? 'this') . ' connections: it reads them on MySQL, MariaDB, PostgreSQL, and SQLite.');
        }
        $driver = Runner::bootedDriver();
        if ($driver !== null && (new \ReflectionMethod($driver, 'sqlSchema'))->getDeclaringClass()->getName() !== 'Runlet\Driver') {
            throw new SqlUnavailable('Runlet can\'t show a definition here: this connection is a callable from ' . $origin . ', so Runlet doesn\'t know its database, and the project driver\'s sqlSchema() lists its tables without a catalog to read definitions from.');
        }

        return $origin === 'WordPress $wpdb' ? ['mysql', 'sqlite'] : ['mysql', 'pgsql', 'sqlite'];
    }

    /**
     * MySQL and MariaDB: SHOW CREATE TABLE (or VIEW), then the table's triggers.
     *
     * @param \PDO|callable $source
     * @return array<string, mixed>
     */
    private static function mysql($source, string $table): array
    {
        $found = self::rows($source, 'mysql', 'SELECT TABLE_TYPE AS table_type FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = :name', ['name' => $table], 1);
        if ($found === []) {
            throw new SqlDefinitionNotFound('There is no table or view named ' . $table . ' in this database. Reload the schema if it was renamed or dropped.');
        }
        $isView = strtoupper((string) self::value($found[0], 'table_type')) === 'VIEW';
        $quoted = self::backticks($table);
        $rows = self::rows($source, 'mysql', ($isView ? 'SHOW CREATE VIEW ' : 'SHOW CREATE TABLE ') . $quoted, [], 1);
        $definition = $rows === [] ? null : (self::value($rows[0], $isView ? 'Create View' : 'Create Table') ?? self::value($rows[0], 1));
        if (!is_string($definition) || trim($definition) === '') {
            throw new \RuntimeException('SHOW CREATE ' . ($isView ? 'VIEW' : 'TABLE') . ' returned no definition.');
        }
        $statements = [self::statement($definition)];
        $notes = [];
        if (!$isView) {
            try {
                $names = self::rows($source, 'mysql', 'SELECT TRIGGER_NAME AS trigger_name FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA = DATABASE() AND EVENT_OBJECT_TABLE = :name ORDER BY ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORDER', ['name' => $table], self::MAX_TRIGGERS);
                foreach ($names as $row) {
                    $name = self::value($row, 'trigger_name');
                    if (!is_string($name) || $name === '') {
                        continue;
                    }
                    $trigger = self::rows($source, 'mysql', 'SHOW CREATE TRIGGER ' . self::backticks($name), [], 1);
                    $text = $trigger === [] ? null : (self::value($trigger[0], 'SQL Original Statement') ?? self::value($trigger[0], 2));
                    if (is_string($text) && trim($text) !== '') {
                        $statements[] = self::statement($text);
                    }
                }
            } catch (DriverFailure $driverFailure) {
                throw $driverFailure;
            } catch (\Throwable $error) {
                $notes[] = 'Triggers could not be read: ' . $error->getMessage();
            }
        }

        return self::result($isView ? 'view' : 'table', $isView ? 'SHOW CREATE VIEW' : 'SHOW CREATE TABLE', $statements, $notes);
    }

    /**
     * SQLite: the object's own CREATE statement, then its indexes and triggers, as written.
     * Indexes SQLite made for PRIMARY KEY and UNIQUE have no SQL of their own.
     *
     * @param \PDO|callable $source
     * @return array<string, mixed>
     */
    private static function sqlite($source, string $table): array
    {
        $found = self::rows($source, 'sqlite', 'SELECT type AS object_type, name AS object_name, sql AS object_sql FROM sqlite_master WHERE name = :name COLLATE NOCASE AND type IN (\'table\', \'view\')', ['name' => $table], 1);
        if ($found === []) {
            throw new SqlDefinitionNotFound('There is no table or view named ' . $table . ' in this database. Reload the schema if it was renamed or dropped.');
        }
        $type = (string) self::value($found[0], 'object_type');
        $sql = self::value($found[0], 'object_sql');
        if (!is_string($sql) || trim($sql) === '') {
            throw new \RuntimeException('sqlite_master has no SQL for ' . $table . '.');
        }
        $statements = [self::statement($sql)];
        $notes = [];
        try {
            $related = self::rows($source, 'sqlite', 'SELECT type AS object_type, sql AS object_sql FROM sqlite_master WHERE tbl_name = :name COLLATE NOCASE AND type IN (\'index\', \'trigger\') AND sql IS NOT NULL ORDER BY CASE type WHEN \'index\' THEN 0 ELSE 1 END, name', ['name' => (string) self::value($found[0], 'object_name')], self::MAX_INDEXES + self::MAX_TRIGGERS);
            foreach ($related as $row) {
                $text = self::value($row, 'object_sql');
                if (is_string($text) && trim($text) !== '') {
                    $statements[] = self::statement($text);
                }
            }
        } catch (DriverFailure $failure) {
            throw $failure;
        } catch (\Throwable $error) {
            $notes[] = 'Indexes and triggers could not be read: ' . $error->getMessage();
        }

        return self::result($type === 'view' ? 'view' : 'table', 'sqlite_master', $statements, $notes);
    }

    /**
     * PostgreSQL: the relation's catalog rows, then the reconstruction (postgres()). The name
     * is the explorer's: bare in the current schema, else `schema.table` in the search path.
     *
     * @param \PDO|callable $source
     * @return array<string, mixed>
     */
    private static function pgsql($source, string $table): array
    {
        $found = self::rows($source, 'pgsql', <<<'SQL'
            SELECT c.oid AS oid, c.relkind AS relkind, c.relpersistence AS relpersistence, c.relispartition AS relispartition,
                quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS qualified,
                array_to_string(c.reloptions, ', ') AS options,
                CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid) END AS partition_key,
                CASE WHEN c.relispartition THEN pg_get_expr(c.relpartbound, c.oid) END AS partition_bound,
                obj_description(c.oid, 'pg_class') AS comment,
                CASE WHEN c.relkind IN ('v', 'm') THEN pg_get_viewdef(c.oid, true) END AS view_definition
            FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND n.nspname = ANY (current_schemas(false))
                AND ((n.nspname = current_schema() AND c.relname = :name) OR n.nspname || '.' || c.relname = :qualified)
            ORDER BY CASE WHEN n.nspname = current_schema() THEN 0 ELSE 1 END
            SQL, ['name' => $table, 'qualified' => $table], 1);
        if ($found === []) {
            throw new SqlDefinitionNotFound('There is no table or view named ' . $table . ' in the search path. Reload the schema if it was renamed or dropped.');
        }
        $relation = self::assoc($found[0]);
        $oid = (int) $relation['oid'];
        $catalog = ['relation' => $relation, 'columns' => [], 'constraints' => [], 'indexes' => [], 'triggers' => [], 'enums' => [], 'parents' => []];
        $catalog['columns'] = self::rows($source, 'pgsql', <<<'SQL'
            SELECT quote_ident(a.attname) AS name, format_type(a.atttypid, a.atttypmod) AS type, a.attnotnull AS not_null,
                pg_get_expr(d.adbin, d.adrelid) AS default_value, a.attidentity AS identity, a.attgenerated AS generated,
                CASE WHEN a.attcollation <> t.typcollation AND a.attcollation <> 0 THEN quote_ident(cn.nspname) || '.' || quote_ident(co.collname) END AS collation,
                col_description(a.attrelid, a.attnum) AS comment
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
            LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
            WHERE a.attrelid = :oid AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            SQL, ['oid' => $oid], self::MAX_COLUMNS);
        $notes = [];
        $extras = [
            'constraints' => ['Constraints', <<<'SQL'
                SELECT quote_ident(conname) AS name, contype AS type, pg_get_constraintdef(oid, true) AS definition
                FROM pg_catalog.pg_constraint WHERE conrelid = :oid AND contype IN ('p', 'u', 'c', 'f', 'x')
                ORDER BY CASE contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 WHEN 'x' THEN 3 ELSE 4 END, conname
                SQL],
            'indexes' => ['Indexes', <<<'SQL'
                SELECT pg_get_indexdef(ix.indexrelid) AS definition
                FROM pg_catalog.pg_index ix JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
                WHERE ix.indrelid = :oid AND NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_constraint k WHERE k.conindid = ix.indexrelid AND k.conrelid = ix.indrelid AND k.contype IN ('p', 'u', 'x'))
                ORDER BY i.relname
                SQL],
            'triggers' => ['Triggers', 'SELECT pg_get_triggerdef(oid, true) AS definition FROM pg_catalog.pg_trigger WHERE tgrelid = :oid AND NOT tgisinternal ORDER BY tgname'],
            'enums' => ['Enum types', <<<'SQL'
                SELECT format_type(t.oid, NULL) AS name, json_agg(e.enumlabel ORDER BY e.enumsortorder)::text AS labels
                FROM pg_catalog.pg_type t JOIN pg_catalog.pg_enum e ON e.enumtypid = t.oid
                WHERE t.oid IN (SELECT atttypid FROM pg_catalog.pg_attribute WHERE attrelid = :oid AND attnum > 0 AND NOT attisdropped)
                GROUP BY t.oid ORDER BY 1
                SQL],
            'parents' => ['Parent tables', <<<'SQL'
                SELECT quote_ident(n.nspname) || '.' || quote_ident(p.relname) AS name
                FROM pg_catalog.pg_inherits i JOIN pg_catalog.pg_class p ON p.oid = i.inhparent JOIN pg_catalog.pg_namespace n ON n.oid = p.relnamespace
                WHERE i.inhrelid = :oid ORDER BY i.inhseqno
                SQL],
        ];
        $isView = in_array($relation['relkind'], ['v', 'm'], true);
        foreach ($extras as $key => [$label, $sql]) {
            if ($isView && in_array($key, ['constraints', 'enums', 'parents'], true)) {
                continue;
            }
            try {
                $catalog[$key] = self::rows($source, 'pgsql', $sql, ['oid' => $oid], self::MAX_INDEXES);
            } catch (DriverFailure $driverFailure) {
                throw $driverFailure;
            } catch (\Throwable $error) {
                $notes[] = $label . ' could not be read: ' . $error->getMessage();
            }
        }
        $built = self::postgres($catalog);
        $built['notes'] = array_merge($built['notes'] ?? [], $notes);
        if ($built['notes'] === []) {
            unset($built['notes']);
        }

        return $built;
    }

    /**
     * Reconstructs PostgreSQL DDL from catalog rows (associative arrays or objects), so it can
     * be checked from recorded rows: `relation` (relkind, relpersistence, relispartition,
     * qualified, options, partition_key, partition_bound, comment, view_definition), `columns`
     * (name, type, not_null, default_value, identity, generated, collation, comment),
     * `constraints` (name, type, definition), `indexes` and `triggers` (definition), `enums`
     * (name, labels as a JSON array), `parents` (name). Names arrive quoted (quote_ident()).
     *
     * @param array<string, mixed> $catalog
     * @return array<string, mixed> `kind`, `how`, `sql`, `reconstructed`, and `notes`
     */
    public static function postgres(array $catalog): array
    {
        $relation = self::assoc($catalog['relation'] ?? []);
        $name = (string) ($relation['qualified'] ?? '');
        $relkind = (string) ($relation['relkind'] ?? 'r');
        $options = isset($relation['options']) && is_string($relation['options']) && $relation['options'] !== '' ? ' WITH (' . $relation['options'] . ')' : '';
        $statements = [];
        $notes = [];
        $kind = 'table';
        if ($relkind === 'v' || $relkind === 'm') {
            $kind = $relkind === 'm' ? 'materialized view' : 'view';
            $definition = rtrim(trim((string) ($relation['view_definition'] ?? '')), ';');
            $statements[] = ($relkind === 'm' ? 'CREATE MATERIALIZED VIEW ' : 'CREATE OR REPLACE VIEW ') . $name . $options . " AS\n" . $definition . ';';
        } else {
            if ($relkind === 'p') {
                $kind = 'partitioned table';
            } elseif ($relkind === 'f') {
                $kind = 'foreign table';
                $notes[] = 'A foreign table: its server and options are left out.';
            }
            $enums = [];
            foreach ($catalog['enums'] ?? [] as $row) {
                $row = self::assoc($row);
                $labels = json_decode((string) ($row['labels'] ?? '[]'), true);
                if (!is_array($labels) || !isset($row['name'])) {
                    continue;
                }
                $enums[] = 'CREATE TYPE ' . $row['name'] . ' AS ENUM (' . implode(', ', array_map([self::class, 'pgLiteral'], array_map('strval', $labels))) . ');';
            }
            if ($enums !== []) {
                $statements[] = "-- Enum types its columns use (defined on their own, not by this table):\n" . implode("\n", $enums);
            }
            $lines = [];
            foreach ($catalog['columns'] ?? [] as $row) {
                $row = self::assoc($row);
                $line = '    ' . $row['name'] . ' ' . $row['type'];
                if (isset($row['collation']) && is_string($row['collation']) && $row['collation'] !== '') {
                    $line .= ' COLLATE ' . $row['collation'];
                }
                $default = isset($row['default_value']) && is_string($row['default_value']) && $row['default_value'] !== '' ? $row['default_value'] : null;
                $generated = (string) ($row['generated'] ?? '');
                $identity = (string) ($row['identity'] ?? '');
                if ($generated === 's' && $default !== null) {
                    $line .= ' GENERATED ALWAYS AS (' . $default . ') STORED';
                } elseif ($identity === 'a' || $identity === 'd') {
                    $line .= ' GENERATED ' . ($identity === 'a' ? 'ALWAYS' : 'BY DEFAULT') . ' AS IDENTITY';
                } elseif ($default !== null) {
                    $line .= ' DEFAULT ' . $default;
                }
                if (SqlSchema::flag($row['not_null'] ?? null) === true) {
                    $line .= ' NOT NULL';
                }
                $lines[] = $line;
            }
            foreach ($catalog['constraints'] ?? [] as $row) {
                $row = self::assoc($row);
                $lines[] = '    CONSTRAINT ' . $row['name'] . ' ' . $row['definition'];
            }
            $create = 'CREATE ' . (($relation['relpersistence'] ?? 'p') === 'u' ? 'UNLOGGED ' : '') . ($relkind === 'f' ? 'FOREIGN ' : '') . 'TABLE ' . $name . " (\n" . implode(",\n", $lines) . "\n)";
            $parents = array_map(static function ($row): string {
                return (string) (self::assoc($row)['name'] ?? '');
            }, $catalog['parents'] ?? []);
            $partitioned = SqlSchema::flag($relation['relispartition'] ?? null) === true;
            if ($parents !== [] && !$partitioned) {
                $create .= "\nINHERITS (" . implode(', ', $parents) . ')';
            }
            if (isset($relation['partition_key']) && is_string($relation['partition_key']) && $relation['partition_key'] !== '') {
                $create .= "\nPARTITION BY " . $relation['partition_key'];
            }
            $create .= $options . ';';
            if ($partitioned && $parents !== []) {
                $create = '-- A partition of ' . $parents[0] . ' ' . ($relation['partition_bound'] ?? '') . ":\n-- ALTER TABLE " . $parents[0] . ' ATTACH PARTITION ' . $name . ' ' . ($relation['partition_bound'] ?? '') . ";\n" . $create;
            }
            $statements[] = $create;
        }
        $indexes = [];
        foreach ($catalog['indexes'] ?? [] as $row) {
            $indexes[] = self::statement((string) (self::assoc($row)['definition'] ?? ''));
        }
        if ($indexes !== []) {
            $statements[] = implode("\n", $indexes);
        }
        foreach ($catalog['triggers'] ?? [] as $row) {
            $statements[] = self::statement((string) (self::assoc($row)['definition'] ?? ''));
        }
        $comments = [];
        if (isset($relation['comment']) && is_string($relation['comment'])) {
            $comments[] = 'COMMENT ON ' . strtoupper($kind === 'partitioned table' ? 'table' : $kind) . ' ' . $name . ' IS ' . self::pgLiteral($relation['comment']) . ';';
        }
        foreach ($catalog['columns'] ?? [] as $row) {
            $row = self::assoc($row);
            if (isset($row['comment']) && is_string($row['comment'])) {
                $comments[] = 'COMMENT ON COLUMN ' . $name . '.' . $row['name'] . ' IS ' . self::pgLiteral($row['comment']) . ';';
            }
        }
        if ($comments !== []) {
            $statements[] = implode("\n", $comments);
        }
        $notes[] = $kind === 'view' || $kind === 'materialized view'
            ? 'Reconstructed by Runlet: the query is PostgreSQL\'s pg_get_viewdef(). Owner and privileges are left out.'
            : 'Reconstructed by Runlet from the catalog (PostgreSQL has no SHOW CREATE TABLE). Owner, privileges, policies, rules, and the sequences behind serial columns are left out.';

        return ['kind' => $kind, 'how' => 'pg_catalog', 'sql' => implode("\n\n", $statements), 'reconstructed' => true, 'notes' => $notes];
    }

    /**
     * @param string[] $statements
     * @param string[] $notes
     * @return array<string, mixed>
     */
    private static function result(string $kind, string $how, array $statements, array $notes): array
    {
        $result = ['kind' => $kind, 'how' => $how, 'sql' => implode("\n\n", $statements)];
        if ($notes !== []) {
            $result['notes'] = $notes;
        }

        return $result;
    }

    /** One statement, ending in exactly one semicolon. */
    private static function statement(string $sql): string
    {
        return rtrim(rtrim(trim($sql)), ';') . ';';
    }

    /**
     * The DDL within MAX_BYTES, cut at a line, with a note when it was cut.
     *
     * @param array<string, mixed> $result
     */
    private static function bounded(string $sql, array &$result): string
    {
        if (preg_match('//u', $sql) !== 1) {
            $sql = (string) preg_replace('/[^\x09\x0A\x0D\x20-\x7E]/', '?', $sql);
        }
        if (strlen($sql) <= self::MAX_BYTES) {
            return $sql;
        }
        $cut = substr($sql, 0, self::MAX_BYTES);
        $line = strrpos($cut, "\n");
        $result['notes'][] = 'The definition is longer than ' . (self::MAX_BYTES >> 20) . ' MB, so Runlet cut it.';

        return $line === false ? $cut : substr($cut, 0, $line);
    }

    /** A MySQL identifier in backticks. */
    private static function backticks(string $name): string
    {
        return '`' . str_replace('`', '``', $name) . '`';
    }

    /** A PostgreSQL string literal (doubled quotes, standard strings). */
    public static function pgLiteral(string $value): string
    {
        return strpos($value, '\\') === false ? "'" . str_replace("'", "''", $value) . "'" : "E'" . str_replace(['\\', "'"], ['\\\\', "''"], $value) . "'";
    }

    /** The server, e.g. "MariaDB 11.4.2", "PostgreSQL 14.13", "SQLite 3.45.1"; null when unknown. */
    private static function server(\PDO $pdo, string $dialect): ?string
    {
        try {
            $version = (string) $pdo->getAttribute(\PDO::ATTR_SERVER_VERSION);
        } catch (\Throwable $error) {
            return null;
        }
        if ($version === '' || strlen($version) > 120) {
            return null;
        }
        if ($dialect === 'mysql') {
            if (stripos($version, 'mariadb') !== false) {
                return 'MariaDB ' . preg_replace('/^(5\.5\.5-)?([0-9.]+).*$/', '$2', $version);
            }

            return 'MySQL ' . preg_replace('/^([0-9.]+).*$/', '$1', $version);
        }

        return ($dialect === 'pgsql' ? 'PostgreSQL ' : 'SQLite ') . preg_replace('/^([0-9.]+).*$/', '$1', $version);
    }

    /**
     * Rows of a catalog query as associative arrays (keys as the query names them, and their
     * positions), at most `$limit`. PDO binds `$params`; a callable gets them as literals.
     *
     * @param \PDO|callable $source
     * @param array<string, string|int> $params
     * @return array<int, array<int|string, mixed>>
     */
    private static function rows($source, string $dialect, string $sql, array $params, int $limit): array
    {
        $rows = [];
        if ($source instanceof \PDO) {
            $source->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
            if ($params === []) {
                $statement = $source->query($sql);
            } else {
                $statement = $source->prepare($sql);
                foreach ($params as $key => $value) {
                    $statement->bindValue(':' . $key, $value, is_int($value) ? \PDO::PARAM_INT : \PDO::PARAM_STR);
                }
                $statement->execute();
            }
            while (($row = $statement->fetch(\PDO::FETCH_BOTH)) !== false) {
                $rows[] = $row;
                if (count($rows) >= $limit) {
                    break;
                }
            }
            $statement->closeCursor();

            return $rows;
        }
        $inline = preg_replace_callback('/(?<!:):([a-z]+)\b/', static function (array $match) use ($params, $dialect): string {
            if (!array_key_exists($match[1], $params)) {
                return $match[0];
            }
            $value = $params[$match[1]];
            if (is_int($value)) {
                return (string) $value;
            }

            return $dialect === 'pgsql' ? self::pgLiteral($value) : ($dialect === 'mysql' ? "'" . str_replace(['\\', "'"], ['\\\\', "''"], $value) . "'" : "'" . str_replace("'", "''", $value) . "'");
        }, $sql);
        $returned = $source((string) $inline);
        if (!is_iterable($returned)) {
            throw new \UnexpectedValueException('the connection returned no rows for the catalog query');
        }
        foreach ($returned as $row) {
            $assoc = is_object($row) ? get_object_vars($row) : (array) $row;
            $rows[] = $assoc + array_values($assoc);
            if (count($rows) >= $limit) {
                break;
            }
        }

        return $rows;
    }

    /**
     * A row's value by name (any case), else by position.
     *
     * @param array<int|string, mixed> $row
     * @param string|int $key
     * @return mixed
     */
    private static function value(array $row, $key)
    {
        if (array_key_exists($key, $row)) {
            return $row[$key];
        }
        if (is_string($key)) {
            foreach ($row as $name => $value) {
                if (is_string($name) && strcasecmp($name, $key) === 0) {
                    return $value;
                }
            }
        }

        return null;
    }

    /**
     * A row as an associative array with lowercase names.
     *
     * @param mixed $row
     * @return array<string, mixed>
     */
    private static function assoc($row): array
    {
        $values = is_object($row) ? get_object_vars($row) : (array) $row;
        $assoc = [];
        foreach ($values as $key => $value) {
            if (is_string($key)) {
                $assoc[strtolower($key)] = $value;
            }
        }

        return $assoc;
    }
}
