import Foundation
import RunletCore
import Testing
@testable import RunletExecution

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct QueryExplainExecutionTests {
    @Test func generatedPHPKeepsSQLAndTypedBindingsWithoutInterpolation() async throws {
        // A scalar result from real PHP proves strings do not interpolate or break out
        // of the generated literals, and verifies PHP's types rather than Swift text.
        let values: [QueryRecord.Binding] = [
            .init(type: "string", value: "'$notAVariable\\\"\n\r\t\0💡"),
            .init(type: "int", value: "9223372036854775807"),
            .init(type: "float", value: "1.25"),
            .init(type: "bool", value: "false"), .init(type: "null"),
            .init(type: "int", value: "-9223372036854775808"),
        ]
        let query = QueryRecord(sql: "select :marker -- $sql\\\"", bindings: values,
                                connection: "reporting'$name", driver: "sqlite")
        let generated = try #require(QueryExplain.code(for: query, style: .pdo))
        let prelude = try #require(generated.range(of: "// Recreate the captured"))
        let code = String(generated[..<prelude.lowerBound]) + "\nreturn json_encode([$sql, $bindings, $connectionName]);"
        let events = try await TestSupport.run(code, target: DriverSupport.target(DriverSupport.fixture("plain")))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let json = try #require(events.result?.value?.scalar)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        #expect(decoded[0] as? String == "EXPLAIN QUERY PLAN " + query.sql)
        #expect(decoded[2] as? String == query.connection)
        let bindings = try #require(decoded[1] as? [Any])
        #expect(bindings[0] as? String == values[0].value)
        #expect((bindings[1] as? NSNumber)?.int64Value == Int64.max)
        #expect((bindings[2] as? NSNumber)?.doubleValue == 1.25)
        #expect((bindings[3] as? NSNumber)?.boolValue == false)
        #expect(bindings[4] is NSNull)
        #expect((bindings[5] as? NSNumber)?.int64Value == Int64.min)
    }

    @Test func pdoPlanRequiresRecreatingConnectionAndKeepsNamedBindings() async throws {
        let query = QueryRecord(sql: "select :name, :enabled, :count", bindings: [
            .init(type: "string", value: "a'$b", name: "name"),
            .init(type: "bool", value: "true", name: "enabled"),
            .init(type: "int", value: "7", name: "count"),
        ], connection: "scratch", driver: "sqlite", databaseAPI: "pdo")
        let generated = try #require(QueryExplain.code(for: query, style: .pdo))
        let target = DriverSupport.target(DriverSupport.fixture("plain"))
        let missing = try await TestSupport.run(generated, target: target)
        #expect(missing.errors.contains { $0.message.contains("Set up the captured PDO connection") })
        // Editing the prepared bindings array must affect the actual bound values.
        let edited = generated.replacingOccurrences(of: "$statement = $pdo->prepare($sql);", with: "$bindings['name'] = 'edited';\n$statement = $pdo->prepare($sql);")
        let events = try await TestSupport.run("$pdo = new PDO('sqlite::memory:');\n\\Runlet\\Inspector::current()->watchPdo($pdo, 'scratch');\n" + edited, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        // #170: the plan card, not the rows.
        let info = try #require(events.sqlPlan)
        #expect(info.dialect == "sqlite" && info.format == "rows" && info.explained == "EXPLAIN QUERY PLAN")
        #expect(info.source == "PDO" && info.connection == "scratch" && info.analyze == false)
        #expect(info.rawText.contains("SCAN CONSTANT ROW"))
        #expect(info.plan?.nodes.isEmpty == false, "\(info.parseError ?? "")")
        #expect(events.result?.hasValue == false)
        #expect(events.inspection.queries.first?.query.bindings.first { $0.name == "name" }?.value == "edited")
    }

    @Test(.enabled(if: ["eloquent-app", "eloquent-app-modern"].allSatisfy {
        FileManager.default.fileExists(atPath: DriverSupport.fixture($0) + "/vendor/autoload.php")
    }, "requires the Eloquent/DBAL 3/4 fixtures"))
    func capturedEloquentAndDoctrineQueriesProducePlansInFreshProcesses() async throws {
        for fixture in ["eloquent-app", "eloquent-app-modern"] {
            let directory = DriverSupport.fixture(fixture)
            let target = DriverSupport.target(directory)
            let events = try await TestSupport.run("Shop\\Models\\Customer::where('name', 'Ada')->get();\n$container->get('reports')->fetchAllAssociative('SELECT name FROM reports WHERE name = ?', ['daily']);", target: target)
            #expect(events.errors.isEmpty, "\(events.errors)")
            let eloquent = try #require(events.inspection.queries.first { $0.query.sql.contains("where") && $0.query.databaseAPI == "eloquent" }?.query)
            let doctrine = try #require(events.inspection.queries.first { $0.query.sql == "SELECT name FROM reports WHERE name = ?" && $0.query.databaseAPI == "doctrine" }?.query)
            for (query, style, setup) in [(eloquent, QueryExplain.ConnectionStyle.eloquent, ""),
                                          (doctrine, .doctrineManual, "$connection = $container->get('reports');\n")] {
                let code = try #require(QueryExplain.code(for: query, style: style))
                let plan = try await TestSupport.run(setup + code, target: target)
                #expect(plan.errors.isEmpty, "\(fixture): \(plan.errors)")
                let info = try #require(plan.sqlPlan, "\(fixture) \(style)")
                #expect(info.dialect == "sqlite" && info.plan?.nodes.isEmpty == false, "\(fixture): \(info.parseError ?? "")")
                #expect(info.source == (style == .eloquent ? "Illuminate database connection" : "Doctrine DBAL"), "\(fixture)")
                #expect(info.connection == query.connection)
                let explained = try #require(plan.inspection.queries.first { $0.query.sql.hasPrefix("EXPLAIN QUERY PLAN ") }?.query)
                #expect(explained.bindings == query.bindings)
                #expect(explained.connection == query.connection)
                #expect(explained.databaseAPI == query.databaseAPI)
            }
        }
    }

    /// #170 (required): a Laravel run on SQLite, whose captured query's Explain tab shows the
    /// plan tree through the same named connection and bindings.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: DriverSupport.fixture("laravel-app") + "/vendor/autoload.php"), "requires the laravel-app fixture"))
    func capturedLaravelQueryShowsThePlanTree() async throws {
        let target = DriverSupport.target(DriverSupport.fixture("laravel-app"))
        let captured = try await TestSupport.run("App\\Models\\Widget::expensive()->pluck('name');", target: target)
        #expect(captured.errors.isEmpty, "\(captured.errors)")
        let query = try #require(captured.inspection.queries.first?.query)
        #expect(query.databaseAPI == "eloquent" && query.driver == "sqlite" && query.connection == "sqlite")
        #expect(query.bindings == [.init(type: "int", value: "100")])
        let code = try #require(QueryExplain.code(for: query, style: .laravel))
        #expect(!code.uppercased().contains("ANALYZE"))
        let events = try await TestSupport.run(code, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let info = try #require(events.sqlPlan)
        #expect(info.driver == "sqlite" && info.dialect == "sqlite" && info.format == "rows")
        #expect(info.explained == "EXPLAIN QUERY PLAN" && info.analyze == false)
        #expect(info.connection == "sqlite" && info.source == "Illuminate database connection")
        #expect(info.serverVersion?.isEmpty == false)
        let plan = try #require(info.plan, "\(info.parseError ?? "")")
        #expect(plan.nodes.first?.operation == "SCAN" && plan.nodes.first?.table == "widgets")
        #expect(plan.fullScans.count == 1)
        #expect(info.originText.hasPrefix("SQLite ") && info.originText.contains("connection “sqlite”"))
        #expect(events.result?.hasValue == false, "the card replaces the dumped rows")
        let explained = try #require(events.inspection.queries.first { $0.query.sql.hasPrefix("EXPLAIN QUERY PLAN ") }?.query)
        #expect(explained.sql == "EXPLAIN QUERY PLAN " + query.sql)
        #expect(explained.bindings == query.bindings)
        #expect(explained.connection == query.connection)
    }

    /// #170: Runlet\explainPlan() on its own: JSON plans by dialect name or by their column,
    /// MariaDB told from MySQL by $wpdb's server version, and rows it can't read (a tabular
    /// MySQL EXPLAIN, PostgreSQL's text plan) returned as they are. Recorded MariaDB 11 and
    /// PostgreSQL 14 output from #147's fixtures.
    @Test func explainPlanHelperReadsJSONPlansAndReturnsOtherRows() async throws {
        let target = DriverSupport.target(DriverSupport.fixture("plain"))
        let mariadb = #"{"query_block":{"select_id":1,"cost":0.0190048,"nested_loop":[{"table":{"table_name":"p147_customers","access_type":"ALL","loops":1,"rows":50,"cost":0.0190048,"filtered":100,"attached_condition":"p147_customers.country = 'UK'"}}]}}"#
        let postgres = #"[{"Plan":{"Node Type":"Seq Scan","Parallel Aware":false,"Async Capable":false,"Relation Name":"p147_customers","Alias":"p147_customers","Startup Cost":0.0,"Total Cost":1.62,"Plan Rows":25,"Plan Width":23,"Filter":"((country)::text = 'UK'::text)"}}]"#
        func run(_ code: String) async throws -> [RunEvent] {
            try await TestSupport.run(code, target: target, magicComments: false)
        }

        let named = try await run("return \\Runlet\\explainPlan([['EXPLAIN' => <<<'JSON'\n\(mariadb)\nJSON\n]], 'mariadb', 'reporting');")
        #expect(named.errors.isEmpty, "\(named.errors)")
        let mariaInfo = try #require(named.sqlPlan)
        #expect(mariaInfo.driver == "mysql" && mariaInfo.dialect == "mariadb" && mariaInfo.format == "json" && mariaInfo.explained == "EXPLAIN FORMAT=JSON")
        #expect(mariaInfo.connection == "reporting" && mariaInfo.analyze == false)
        #expect(mariaInfo.plan?.fullScans.count == 1, "\(mariaInfo.parseError ?? "")")
        #expect(named.result?.hasValue == false)

        let inferred = try await run("return \\Runlet\\explainPlan([(object) ['QUERY PLAN' => <<<'JSON'\n\(postgres)\nJSON\n]]);")
        let pgInfo = try #require(inferred.sqlPlan)
        #expect(pgInfo.dialect == "pgsql" && pgInfo.explained == "EXPLAIN (FORMAT JSON)" && pgInfo.connection == nil)
        #expect(pgInfo.plan?.nodes.first?.operation == "Seq Scan", "\(pgInfo.parseError ?? "")")

        // The generated WordPress tab on MySQL, with a stand-in $wpdb (no WordPress here): MariaDB
        // by db_server_info(), and the SQL it was asked to run.
        let query = QueryRecord(sql: "SELECT * FROM p147_customers WHERE country = 'UK'", connection: "wpdb", driver: "mysql", databaseAPI: "wordpress")
        let generated = try #require(QueryExplain.code(for: query, style: .wordpress))
        let wpdb = """
        class wpdb {
            public $last_error = '';
            public function get_results($sql, $output) {
                if ($sql !== "EXPLAIN FORMAT=JSON SELECT * FROM p147_customers WHERE country = 'UK'" || $output !== ARRAY_A) {
                    throw new LogicException('Unexpected SQL: ' . $sql);
                }
                return [['EXPLAIN' => <<<'JSON'
        \(mariadb)
        JSON
                ]];
            }
            public function db_server_info() { return '5.5.5-11.8.2-MariaDB-ubu2404'; }
        }
        const ARRAY_A = 'ARRAY_A';
        $wpdb = new wpdb();

        """
        let wordpress = try await run(wpdb + generated)
        #expect(wordpress.errors.isEmpty, "\(wordpress.errors)")
        let wpInfo = try #require(wordpress.sqlPlan)
        #expect(wpInfo.dialect == "mariadb" && wpInfo.source == "WordPress $wpdb" && wpInfo.connection == "wpdb")
        #expect(wpInfo.databaseName == "MariaDB 11.8.2")
        #expect(wpInfo.plan?.fullScans.count == 1)

        // Rows that aren't a plan the card reads come back as they are, and no card is shown.
        let tabular = try await run("return \\Runlet\\explainPlan([['id' => 1, 'select_type' => 'SIMPLE', 'table' => 'p147_customers', 'type' => 'ALL']], 'mysql');")
        #expect(tabular.sqlPlan == nil)
        #expect(tabular.result?.value?.count == 1)
        let text = try await run("return \\Runlet\\explainPlan([['QUERY PLAN' => 'Seq Scan on p147_customers  (cost=0.00..1.62 rows=25 width=23)']], 'pgsql');")
        #expect(text.sqlPlan == nil)
        #expect(text.result?.value?.count == 1)
        let none = try await run("return \\Runlet\\explainPlan([], 'sqlite');")
        #expect(none.sqlPlan == nil && none.errors.isEmpty)
    }

    /// #170: the helper and the generated PDO tab on PHP 7.4.
    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func pdoPlanOnPHP74() async throws {
        let query = QueryRecord(sql: "select :name", bindings: [.init(type: "string", value: "a", name: "name")], connection: "scratch", driver: "sqlite", databaseAPI: "pdo")
        let generated = try #require(QueryExplain.code(for: query, style: .pdo))
        let target = DriverSupport.target(DriverSupport.fixture("plain"), php: TestSupport.herdPHP74)
        let events = try await TestSupport.run("$pdo = new PDO('sqlite::memory:');\n" + generated, target: target)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.sqlPlan?.plan?.nodes.isEmpty == false)
        #expect(events.sqlPlan?.connection == "scratch")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path), "requires the WordPress SQLite fixture"))
    func wordpressSQLiteCaptureDoesNotOfferAnUnsupportedPlan() async throws {
        let target = DriverSupport.target(DriverSupport.fixture("wordpress"))
        let captured = try await TestSupport.run("$wpdb->get_var(\"SELECT COUNT(*) FROM {$wpdb->posts}\");", target: target)
        #expect(captured.errors.isEmpty, "\(captured.errors)")
        let query = try #require(captured.inspection.queries.last?.query)
        #expect(query.databaseAPI == "wordpress")
        #expect(query.driver == "sqlite")
        #expect(QueryExplain.unavailableReason(for: query)?.contains("WordPress's SQLite") == true)
        #expect(QueryExplain.code(for: query, style: .wordpress) == nil)
    }
}
