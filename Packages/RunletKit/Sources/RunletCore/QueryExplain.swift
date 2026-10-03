import Foundation

/// #4: prepares editable PHP, never a run request. Bindings stay separate from SQL;
/// the inspector's interpolated SQL is only a display representation.
///
/// #170: the EXPLAIN asks for the format #147's plan tree reads (`EXPLAIN FORMAT=JSON` on
/// MySQL and MariaDB, `EXPLAIN (FORMAT JSON)` on PostgreSQL, `EXPLAIN QUERY PLAN` on SQLite),
/// and the code hands its rows to the runner's `Runlet\explainPlan()`, which shows them as the
/// plan card (an `sqlPlan` event). A capture without a known driver keeps a plain `EXPLAIN`
/// whose rows are returned as they are. It never adds `ANALYZE`.
public enum QueryExplain {
    public enum ConnectionStyle: Sendable {
        case laravel, eloquent, doctrine, doctrineManual, wordpress, pdo
    }

    /// The EXPLAIN put in front of the captured SQL, by the captured driver.
    static func prefix(for driver: String?) -> String {
        switch driver?.lowercased() {
        case "sqlite", "sqlite3": "EXPLAIN QUERY PLAN"
        case "mysql", "mariadb": "EXPLAIN FORMAT=JSON"
        case "pgsql", "postgresql": "EXPLAIN (FORMAT JSON)"
        default: "EXPLAIN"
        }
    }

    public static func unavailableReason(for query: QueryRecord) -> String? {
        if query.databaseAPI == "wordpress", ["sqlite", "sqlite3"].contains(query.driver?.lowercased() ?? "") {
            return "WordPress's SQLite translation layer does not return Explain plans through wpdb."
        }
        if (query.omittedBytes ?? 0) > 0 || (query.omittedBindings ?? 0) > 0 {
            return "Explain needs the complete SQL and all bindings; this capture was truncated."
        }
        if query.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "There is no SQL to explain."
        }
        if let driver = query.driver?.lowercased(), !["mysql", "mariadb", "pgsql", "postgresql", "sqlite", "sqlite3"].contains(driver) {
            return "Explain is not available for the captured database driver (\(driver))."
        }
        if query.bindings.contains(where: { ($0.omittedBytes ?? 0) > 0 || phpValue($0) == nil }) {
            return "Explain needs complete scalar bindings; a binding was truncated or cannot be recreated."
        }
        return nil
    }

    public static func code(for query: QueryRecord, style: ConnectionStyle) -> String? {
        guard unavailableReason(for: query) == nil else { return nil }
        let explain = prefix(for: query.driver)
        // The plan card reads the JSON formats and SQLite's rows; a plain EXPLAIN's rows are
        // returned as they are.
        let plans = explain != "EXPLAIN"
        func show(_ connection: String) -> String {
            guard plans else { return "return $plan;" }
            return """
            // Runlet shows the plan as a tree, with the database's own output under Raw.
            return function_exists('Runlet\\explainPlan') ? \\Runlet\\explainPlan($plan, \(connection), $connectionName) : $plan;
            """
        }
        let bindings = query.bindings.enumerated().map { index, binding in
            let key = binding.name.map { phpString($0) } ?? String(index)
            return "    \(key) => \(phpValue(binding)!),"
        }.joined(separator: "\n")
        let header = """
        // Review this plan request, then press Run.
        // Opening or restoring this tab never runs it.
        $sql = \(phpString(explain + " " + query.sql));
        $bindings = [
        \(bindings)
        ];
        $connectionName = \(query.connection.map(phpString) ?? "null");

        """
        switch style {
        case .laravel:
            return header + """
            $connection = \\Illuminate\\Support\\Facades\\DB::connection($connectionName);
            $plan = $connection->select($sql, $bindings);
            \(show("$connection"))
            """
        case .eloquent:
            return header + """
            $connection = \\Illuminate\\Database\\Eloquent\\Model::resolveConnection($connectionName);
            $plan = $connection->select($sql, $bindings);
            \(show("$connection"))
            """
        case .doctrine, .doctrineManual:
            let types = query.bindings.enumerated().map { index, binding in
                let key = binding.name.map { phpString($0) } ?? String(index)
                return "    \(key) => \\Doctrine\\DBAL\\ParameterType::\(parameterType(binding)),"
            }.joined(separator: "\n")
            let connection = style == .doctrine ? "$connection = $container->get('doctrine')->getConnection($connectionName);" : """
            // Recreate the captured $connectionName connection as $connection here.
            // Each Run starts a fresh PHP process; variables from the original tab are not shared.
            if (!isset($connection) || !$connection instanceof \\Doctrine\\DBAL\\Connection) {
                throw new \\RuntimeException('Set up the captured DBAL connection as $connection before running Explain.');
            }
            """
            return header + """
            \(connection)
            $types = [
            \(types)
            ];
            $plan = $connection->executeQuery($sql, $bindings, $types)->fetchAllAssociative();
            \(show("$connection"))
            """
        case .wordpress:
            // wpdb reports the SQL it executed, with values already substituted.
            guard query.bindings.isEmpty else { return nil }
            return header + """
            $plan = $wpdb->get_results($sql, ARRAY_A);
            if ($wpdb->last_error !== '') {
                throw new \\RuntimeException($wpdb->last_error);
            }
            \(show("$wpdb"))
            """
        case .pdo:
            let bind = query.bindings.enumerated().map { index, binding in
                let key = binding.name.map { phpString(":" + $0) } ?? String(index + 1)
                let valueKey = binding.name.map(phpString) ?? String(index)
                return "$statement->bindValue(\(key), $bindings[\(valueKey)], \\PDO::PARAM_\(pdoParameterType(binding)));"
            }.joined(separator: "\n")
            return header + """
            // Recreate the captured $connectionName connection as $pdo here.
            // Each Run starts a fresh PHP process; variables from the original tab are not shared.
            if (!isset($pdo) || !$pdo instanceof \\PDO) {
                throw new \\RuntimeException('Set up the captured PDO connection as $pdo before running Explain.');
            }
            $statement = $pdo->prepare($sql);
            \(bind)
            $statement->execute();
            $plan = $statement->fetchAll(\\PDO::FETCH_ASSOC);
            \(show("$pdo"))
            """
        }
    }

    /// PHP double-quoted strings with no variable interpolation or control characters.
    /// Shared with SQL tabs (#35), whose generated PHP carries the statement the same way.
    static func phpString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\0", with: "\\x00") + "\""
    }

    private static func phpValue(_ binding: QueryRecord.Binding) -> String? {
        switch binding.type {
        case "null": return "null"
        case "bool": return ["true", "false"].contains(binding.value ?? "") ? binding.value : nil
        case "int":
            guard let value = binding.value, let integer = Int64(value) else { return nil }
            // PHP parses the positive magnitude of Int64.min as a float before negating.
            return integer == Int64.min ? "(int) \(phpString(value))" : String(integer)
        case "float":
            guard let value = binding.value, Double(value)?.isFinite == true,
                  value.range(of: #"^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
            return "(float) \(phpString(value))"
        case "string", "datetime": return binding.value.map(phpString)
        default: return nil
        }
    }

    private static func parameterType(_ binding: QueryRecord.Binding) -> String {
        switch binding.type {
        case "null": "NULL"
        case "bool": "BOOLEAN"
        case "int": "INTEGER"
        default: "STRING"
        }
    }

    private static func pdoParameterType(_ binding: QueryRecord.Binding) -> String {
        switch binding.type {
        case "null": "NULL"
        case "bool": "BOOL"
        case "int": "INT"
        default: "STR"
        }
    }
}
