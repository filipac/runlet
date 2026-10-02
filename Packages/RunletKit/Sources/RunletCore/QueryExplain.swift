import Foundation

/// #4: prepares editable PHP, never a run request. Bindings stay separate from SQL;
/// the inspector's interpolated SQL is only a display representation.
public enum QueryExplain {
    public enum ConnectionStyle: Sendable {
        case laravel, eloquent, doctrine, doctrineManual, wordpress, pdo
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
        let prefix = ["sqlite", "sqlite3"].contains(query.driver?.lowercased() ?? "") ? "EXPLAIN QUERY PLAN " : "EXPLAIN "
        let bindings = query.bindings.enumerated().map { index, binding in
            let key = binding.name.map { string($0) } ?? String(index)
            return "    \(key) => \(phpValue(binding)!),"
        }.joined(separator: "\n")
        let header = """
        // Review this plan request, then press Run.
        // Opening or restoring this tab never runs it.
        $sql = \(string(prefix + query.sql));
        $bindings = [
        \(bindings)
        ];
        $connectionName = \(query.connection.map(string) ?? "null");

        """
        switch style {
        case .laravel:
            return header + """
            $connection = \\Illuminate\\Support\\Facades\\DB::connection($connectionName);
            return $connection->select($sql, $bindings);
            """
        case .eloquent:
            return header + """
            $connection = \\Illuminate\\Database\\Eloquent\\Model::resolveConnection($connectionName);
            return $connection->select($sql, $bindings);
            """
        case .doctrine, .doctrineManual:
            let types = query.bindings.enumerated().map { index, binding in
                let key = binding.name.map { string($0) } ?? String(index)
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
            return $connection->executeQuery($sql, $bindings, $types)->fetchAllAssociative();
            """
        case .wordpress:
            // wpdb reports the SQL it executed, with values already substituted.
            guard query.bindings.isEmpty else { return nil }
            return header + """
            $plan = $wpdb->get_results($sql, ARRAY_A);
            if ($wpdb->last_error !== '') {
                throw new \\RuntimeException($wpdb->last_error);
            }
            return $plan;
            """
        case .pdo:
            let bind = query.bindings.enumerated().map { index, binding in
                let key = binding.name.map { string(":" + $0) } ?? String(index + 1)
                return "$statement->bindValue(\(key), \(phpValue(binding)!), \\PDO::PARAM_\(pdoParameterType(binding)));"
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
            return $statement->fetchAll(\\PDO::FETCH_ASSOC);
            """
        }
    }

    /// PHP double-quoted strings with no variable interpolation or control characters.
    private static func string(_ value: String) -> String {
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
            return integer == Int64.min ? "(int) \(string(value))" : String(integer)
        case "float":
            guard let value = binding.value, Double(value)?.isFinite == true,
                  value.range(of: #"^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
            return "(float) \(string(value))"
        case "string", "datetime": return binding.value.map(string)
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
