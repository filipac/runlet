import Foundation
import RunletCore
import Testing
@testable import RunletExecution

private extension Array where Element == RunEvent {
    var notices: [String] {
        compactMap { if case .notice(let message) = $0.kind { return message } else { return nil } }
    }

    var queries: [QueryRecord] {
        inspection.queries.map(\.query)
    }
}

private extension RunInspection {
    func titles(in section: String) -> [String?] {
        records(in: section).map(\.title)
    }
}

private func fixtureReady(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("\(name)/vendor/autoload.php").path)
}

// MARK: - Driver API (no framework)

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct InspectorAPITests {
    static let customSectionDriver = """
    <?php
    class SectionsDriver extends \\Runlet\\Driver
    {
        public function bootstrap(string $projectPath): void
        {
        }

        public function inspect(\\Runlet\\Inspector $inspector): void
        {
            $inspector->section('Events');
            $GLOBALS['fire'] = static function (string $name, $payload) use ($inspector): void {
                $inspector->record('Events', $name, $payload);
            };
        }
    }
    """

    @Test func customSectionsLogsAndHTMLFromADriverAndTheSnippet() async throws {
        let directory = try DriverSupport.composerProject(drivers: ["SectionsDriver.php": Self.customSectionDriver])
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("""
        $GLOBALS['fire']('order.placed', ['id' => 7, 'total' => 12.5]);
        $inspector = \\Runlet\\Inspector::current();
        $inspector->log('warning', 'Low stock', ['sku' => 'A-1']);
        $inspector->html('Receipt', '<h1>Thanks</h1>');
        $inspector->query('select * from t where id = ?', [7], 1.25, 'main');
        'done'
        """, target: DriverSupport.target(directory.path))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let info = try #require(events.inspectorInfo)
        #expect(info.sections == ["Events"])
        #expect(info.driverName == "SectionsDriver")
        let inspection = events.inspection
        #expect(inspection.sections == ["Queries", "Log", "Events", "HTML"], "\(inspection.sections)")

        let event = try #require(inspection.records(in: "Events").first)
        #expect(event.title == "order.placed")
        #expect(event.inSnippet == true && event.snippetLine == 1)
        guard case .value(let payload) = event.content else { Issue.record("expected a value record"); return }
        #expect(payload.entries?.map(\.key) == ["id", "total"])

        let log = try #require(inspection.records(in: "Log").first)
        guard case .log(let entry) = log.content else { Issue.record("expected a log record"); return }
        #expect(entry.level == "warning" && entry.message == "Low stock")
        #expect(entry.context?.entries?.first?.value.scalar == "A-1")
        #expect(log.snippetLine == 3)

        let html = try #require(inspection.records(in: "HTML").first)
        #expect(html.title == "Receipt")
        #expect(html.content == .html(HTMLRecord(html: "<h1>Thanks</h1>", omittedBytes: nil)))

        let query = try #require(inspection.queries.first?.query)
        #expect(query.sql == "select * from t where id = ?")
        #expect(query.bindings == [QueryRecord.Binding(type: "int", value: "7")])
        #expect(query.timeMs == 1.25 && query.connection == "main")
        #expect(query.interpolatedSQL == "select * from t where id = 7")
        // Records arrive in run order.
        #expect(inspection.records.map(\.index) == [1, 2, 3, 4])
    }

    @Test func failingInspectHookIsANoticeAndTheRunContinues() async throws {
        let directory = try DriverSupport.composerProject(drivers: ["BrokenDriver.php": """
        <?php
        class BrokenDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
            }

            public function inspect(\\Runlet\\Inspector $inspector): void
            {
                throw new \\RuntimeException('no events here');
            }
        }
        """])
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("40 + 2", target: DriverSupport.target(directory.path))
        #expect(events.result?.value?.scalar == "42")
        #expect(events.errors.isEmpty)
        #expect(events.notices.contains { $0.contains("BrokenDriver (.runlet/BrokenDriver.php) failed in inspect(): no events here") }, "\(events.notices)")
        #expect(events.inspectorInfo != nil)
    }

    @Test func disabledInspectorRecordsNothing() async throws {
        let directory = try DriverSupport.composerProject(drivers: ["SectionsDriver.php": Self.customSectionDriver])
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("""
        \\Runlet\\Inspector::current()->record('Events', 'x', 1);
        isset($GLOBALS['fire'])
        """, target: DriverSupport.target(directory.path), inspector: RunInspectorOptions(enabled: false))
        #expect(events.result?.value?.scalar == "false", "inspect() must not run: \(events.errors)")
        #expect(events.inspection.isEmpty)
        #expect(events.inspectorInfo == nil)
    }

    @Test func runnerLimitsReportWhatTheyLeftOut() async throws {
        var limits = RunLimits()
        limits.maxQueries = 3
        limits.maxRecords = 2
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, limits: limits)
        let target = TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: TestSupport.php()!)
        let events = try await TestSupport.run("""
        $inspector = \\Runlet\\Inspector::current();
        for ($i = 0; $i < 10; $i++) { $inspector->query('select ' . $i); $inspector->record('Loop', (string) $i, $i); }
        """, target: target, engine: engine)
        let inspection = events.inspection
        #expect(inspection.queries.count == 3)
        #expect(inspection.records(in: "Loop").count == 2)
        #expect(inspection.omitted(in: "Queries") == RecordLimitInfo(section: "Queries", omitted: 7, reason: "count"))
        #expect(inspection.omitted(in: "Loop") == RecordLimitInfo(section: "Loop", omitted: 8, reason: "count"))
    }

    /// A driver that writes record frames itself cannot get past Runlet's own backstop.
    @Test func appBackstopDropsRecordsBeyondTheLimits() async throws {
        var limits = RunLimits()
        limits.maxQueries = 2
        limits.maxRecords = 2
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, limits: limits)
        let target = TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: TestSupport.php()!)
        let events = try await TestSupport.run("""
        for ($i = 1; $i <= 9; $i++) {
            \\RunletRunner\\Channel::emit('record', ['index' => $i, 'section' => 'Raw', 'kind' => 'value', 'title' => (string) $i, 'data' => ['value' => ['id' => 1, 'type' => 'int', 'scalar' => (string) $i]]]);
        }
        """, target: target, engine: engine)
        let inspection = events.inspection
        #expect(inspection.records(in: "Raw").count == 4)
        #expect(inspection.omitted(in: "Raw") == RecordLimitInfo(section: "Raw", omitted: 5, reason: "app"))
        if case .finished = events.last?.kind {} else { Issue.record("finished is not last") }
    }

    @Test func watchedPDORecordsPreparedStatements() async throws {
        let target = TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: TestSupport.php()!)
        let events = try await TestSupport.run("""
        $pdo = new PDO('sqlite::memory:');
        $pdo->exec('create table t (id integer, name text)');
        \\Runlet\\Inspector::current()->watchPdo($pdo, 'scratch');
        $insert = $pdo->prepare('insert into t values (:id, :name)');
        $insert->execute(['id' => 1, 'name' => "O'Hara"]);
        $select = $pdo->prepare('select name from t where id = ?');
        $id = 1;
        $select->bindParam(1, $id, PDO::PARAM_INT);
        $select->execute();
        $select->fetchColumn()
        """, target: target)
        #expect(events.result?.value?.scalar == "O'Hara", "\(events.errors) \(events.stderr)")
        let queries = events.queries
        #expect(queries.map(\.sql) == ["insert into t values (:id, :name)", "select name from t where id = ?"])
        #expect(queries.first?.interpolatedSQL == "insert into t values (1, 'O''Hara')")
        #expect(queries.last?.bindings == [QueryRecord.Binding(type: "int", value: "1")])
        #expect(queries.allSatisfy { $0.connection == "scratch" && $0.driver == "sqlite" && $0.timeMs != nil })
        #expect(events.inspection.records(in: "Queries").map(\.snippetLine) == [5, 9])
    }

    @Test func mailInterceptionThatNoDriverSupportsIsReported() async throws {
        let target = TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: TestSupport.php()!)
        let events = try await TestSupport.run("1", target: target, inspector: RunInspectorOptions(interceptMail: true))
        let info = try #require(events.inspectorInfo)
        #expect(info.interceptMail && !info.interceptingMail && info.interceptionUnsupported)
    }

    @Test func commandListingNeverInspects() throws {
        let frames = try DriverSupport.rawFrames("1", directory: DriverSupport.fixture("composer"))
        #expect(!frames.contains { $0.type == "inspector" || $0.type == "record" })
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func driverAPIRunsOnPHP74() async throws {
        let directory = try DriverSupport.composerProject(drivers: ["SectionsDriver.php": Self.customSectionDriver])
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("""
        $GLOBALS['fire']('order.placed', ['id' => 7]);
        $pdo = new PDO('sqlite::memory:');
        \\Runlet\\Inspector::current()->watchPdo($pdo);
        $statement = $pdo->prepare('select ? as answer');
        $statement->execute([42]);
        [PHP_VERSION, $statement->fetchColumn()]
        """, target: DriverSupport.target(directory.path, php: TestSupport.herdPHP74!))
        #expect(events.errors.isEmpty, "\(events.errors) \(events.stderr)")
        #expect(events.result?.value?.entries?.first?.value.scalar?.hasPrefix("7.4") == true)
        #expect(events.inspection.records(in: "Events").first?.title == "order.placed")
        #expect(events.queries.first?.interpolatedSQL == "select 42 as answer")
    }
}

// MARK: - Eloquent without Laravel, Doctrine DBAL

/// Tests/Fixtures/eloquent-app: a Slim-style app that boots Eloquent through Capsule
/// (illuminate/database 8 with illuminate/events) and Doctrine DBAL 3, via a project driver.
@Suite(.enabled(if: TestSupport.hasPHP && fixtureReady("eloquent-app"), "requires scripts/setup-fixtures.sh"))
struct EloquentInspectorTests {
    static let snippet = """
    use Shop\\Models\\Customer;
    use Shop\\Cache;

    $counts = [];
    foreach (Customer::all() as $customer) {
        $counts[] = $customer->orders()->count();
    }
    $reports = $container->get('reports')->fetchAllAssociative('SELECT name FROM reports WHERE name = ?', ['daily']);
    Cache::remember('top', function () { return Customer::where('name', 'Ada')->first()->name; });
    Cache::remember('top', function () { return 'unused'; });
    [$counts, count($reports)]
    """

    static func check(_ events: [RunEvent], liveEloquent: Bool) throws {
        #expect(events.errors.isEmpty, "\(events.errors) \(events.stderr)")
        let inspection = events.inspection
        #expect(inspection.sections == ["Queries", "Cache"])
        let records = inspection.records(in: "Queries")
        let queries = records.compactMap(\.query)
        #expect(queries.count == 6)
        let eloquent = queries.filter { $0.connection == "default" }
        #expect(eloquent.count == 5)
        #expect(eloquent.allSatisfy { $0.driver == "sqlite" && $0.timeMs != nil })
        #expect(eloquent.first?.sql == #"select * from "customers""#)
        let counts = eloquent.filter { $0.sql.hasPrefix("select count(*)") }
        #expect(counts.map { $0.bindings.first?.value } == ["1", "2", "3"])
        #expect(counts.first?.interpolatedSQL.contains(#""orders"."customer_id" = 1"#) == true)

        let doctrine = try #require(queries.first { $0.connection == "reports" })
        #expect(doctrine.sql == "SELECT name FROM reports WHERE name = ?")
        #expect(doctrine.interpolatedSQL == "SELECT name FROM reports WHERE name = 'daily'")
        #expect(doctrine.driver == "sqlite")

        // Snippet lines for every statement, also from the query-log fallback.
        let lines = Dictionary(grouping: records, by: { $0.query?.connection ?? "" }).mapValues { $0.compactMap(\.snippetLine).sorted() }
        #expect(lines["default"] == [5, 6, 6, 6, 9])
        #expect(lines["reports"] == [8])
        if liveEloquent {
            #expect(records.compactMap(\.snippetLine) == [5, 6, 6, 6, 8, 9])
        }

        // The N+1 the loop causes.
        let analysis = QueryAnalysis(inspection.queries)
        let flagged = try #require(analysis.flaggedGroups.first)
        #expect(flagged.hints == [.nPlusOne(count: 3)])

        // The fixture driver's own "Cache" section.
        #expect(inspection.titles(in: "Cache") == ["miss top", "write top", "hit top"])
    }

    @Test func capsuleWithoutADispatcherGetsOneForTheRun() async throws {
        let events = try await TestSupport.run(Self.snippet, target: DriverSupport.target(DriverSupport.fixture("eloquent-app")))
        try Self.check(events, liveEloquent: true)
    }

    /// The app gives Capsule its own dispatcher: Runlet listens on it instead of adding one.
    @Test func capsuleWithTheAppsOwnDispatcher() async throws {
        let directory = try DriverSupport.temporaryDirectory("eloquent-events")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = TestSupport.fixtures.appendingPathComponent("eloquent-app")
        for entry in try FileManager.default.contentsOfDirectory(atPath: app.path) where entry != ".runlet" {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(entry), withDestinationURL: app.appendingPathComponent(entry))
        }
        try DriverSupport.write([".runlet/EventsShopDriver.php": """
        <?php
        require_once '\(app.path)/.runlet/ShopDriver.php';

        class EventsShopDriver extends ShopDriver
        {
            public function bootstrap(string $projectPath): void
            {
                putenv('SHOP_EVENTS=1');
                parent::bootstrap($projectPath);
                $GLOBALS['appDispatcher'] = \\Illuminate\\Database\\Eloquent\\Model::getEventDispatcher();
            }
        }
        """], into: directory)
        let events = try await TestSupport.run(Self.snippet, target: DriverSupport.target(directory.path))
        #expect(events.bootstrapped?.framework == "custom:EventsShopDriver")
        try Self.check(events, liveEloquent: true)
        let same = try await TestSupport.run("$GLOBALS['appDispatcher'] !== null && $GLOBALS['appDispatcher'] === \\Shop\\Models\\Customer::query()->getConnection()->getEventDispatcher()", target: DriverSupport.target(directory.path))
        #expect(same.result?.value?.scalar == "true", "\(same.errors)")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func onPHP74() async throws {
        let events = try await TestSupport.run(Self.snippet, target: DriverSupport.target(DriverSupport.fixture("eloquent-app"), php: TestSupport.herdPHP74!))
        try Self.check(events, liveEloquent: true)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
    }

    /// Tests/Fixtures/eloquent-app-modern: illuminate/database 13 without illuminate/events
    /// (query-log fallback) and Doctrine DBAL 4 (middleware).
    @Test(.enabled(if: fixtureReady("eloquent-app-modern"), "requires scripts/setup-fixtures.sh"))
    func queryLogFallbackAndDBAL4() async throws {
        let events = try await TestSupport.run(Self.snippet, target: DriverSupport.target(DriverSupport.fixture("eloquent-app-modern")))
        try Self.check(events, liveEloquent: false)
        // illuminate/database 13 renders the statement with its bindings itself.
        #expect(events.queries.first { $0.sql.contains(#""name" = ?"#) }?.rawSql == #"select * from "customers" where "name" = 'Ada' limit 1"#)
    }
}

// MARK: - Laravel: queries, mail, logs, previews

@Suite(.serialized, .enabled(if: TestSupport.hasPHP && fixtureReady("laravel-app"), "requires scripts/setup-fixtures.sh"))
struct LaravelInspectorTests {
    var target: TargetSnapshot { DriverSupport.target(DriverSupport.fixture("laravel-app")) }

    /// The array mailer keeps sent messages in memory: nothing leaves the machine, and the
    /// snippet's result counts what was really sent.
    static let sendMail = """
    config(['mail.default' => 'array']);
    Illuminate\\Support\\Facades\\Mail::to('ada@example.com', 'Ada')->cc('grace@example.com')->send(new class extends Illuminate\\Mail\\Mailable {
        public function build() { return $this->subject('Welcome aboard')->html('<h1>Hi</h1>'); }
    });
    Illuminate\\Support\\Facades\\Mail::mailer('array')->getSymfonyTransport()->messages()->count()
    """

    @Test func queriesLogsAndMailAreRecorded() async throws {
        let events = try await TestSupport.run("""
        use App\\Models\\Widget;
        use Illuminate\\Support\\Facades\\Log;

        $names = Widget::expensive()->pluck('name');
        Log::warning('Expensive widgets', ['count' => $names->count()]);
        """ + "\n" + Self.sendMail, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "1", "the mail is sent when interception is off")
        let info = try #require(events.inspectorInfo)
        #expect(info.sections == ["Queries", "Mail", "Log"])
        #expect(!info.interceptMail && !info.interceptingMail)

        let inspection = events.inspection
        let query = try #require(inspection.queries.first?.query)
        #expect(query.sql == #"select "name" from "widgets" where "price" > ?"#)
        #expect(query.rawSql == #"select "name" from "widgets" where "price" > 100"#)
        #expect(query.connection == "sqlite")
        #expect(inspection.records(in: "Queries").first?.snippetLine == 4)

        let log = try #require(inspection.records(in: "Log").first)
        guard case .log(let entry) = log.content else { Issue.record("expected a log record"); return }
        #expect(entry.level == "warning" && entry.message == "Expensive widgets")

        let mail = try #require(inspection.mails.first)
        #expect(mail.subject == "Welcome aboard")
        #expect(mail.to == [MailRecord.Address(address: "ada@example.com", name: "Ada")])
        #expect(mail.cc.map(\.address) == ["grace@example.com"])
        #expect(mail.from.first?.address == "hello@example.com")
        #expect(mail.html == "<h1>Hi</h1>")
        #expect(mail.mailer == "array")
        #expect(mail.mailable == "Illuminate\\Mail\\Mailable@anonymous")
        #expect(!mail.intercepted)
        #expect(inspection.interceptedMailCount == 0)
    }

    @Test func interceptedMailIsRecordedButNotSent() async throws {
        let events = try await TestSupport.run(Self.sendMail, target: target, inspector: RunInspectorOptions(interceptMail: true))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "0", "the array transport must not have received the message")
        let info = try #require(events.inspectorInfo)
        #expect(info.interceptMail && info.interceptingMail)
        let mail = try #require(events.inspection.mails.first)
        #expect(mail.intercepted && mail.subject == "Welcome aboard")
        #expect(events.inspection.interceptedMailCount == 1)
    }

    @Test func returnedAndDumpedMailHaveHTMLPreviews() async throws {
        let events = try await TestSupport.run("""
        use Illuminate\\Notifications\\Messages\\MailMessage;

        dump((new MailMessage)->subject('Invoice')->line('Thanks for your order.'));
        new class extends Illuminate\\Mail\\Mailable {
            public function build() { return $this->subject('Welcome')->html('<p>Hello <b>Ada</b></p>'); }
        }
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let dumped = try #require(events.dumps.first?.preview)
        #expect(dumped.kind == "mail" && dumped.subject == "Invoice")
        #expect(dumped.html?.contains("Thanks for your order.") == true)
        #expect(dumped.text?.contains("Thanks for your order.") == true)
        let returned = try #require(events.result?.preview)
        #expect(returned.title == "Illuminate\\Mail\\Mailable@anonymous")
        #expect(returned.subject == "Welcome" && returned.html == "<p>Hello <b>Ada</b></p>")

        let off = try await TestSupport.run("new Illuminate\\Support\\HtmlString('<b>x</b>')", target: target, inspector: RunInspectorOptions(previews: false))
        #expect(off.result?.preview == nil)
        let html = try await TestSupport.run("new Illuminate\\Support\\HtmlString('<b>x</b>')", target: target)
        #expect(html.result?.preview?.html == "<b>x</b>")
    }

    @Test func previewErrorsAreReportedOnThePreview() async throws {
        let events = try await TestSupport.run("""
        new class extends Illuminate\\Mail\\Mailable {
            public function build() { throw new RuntimeException('template missing'); }
        }
        """, target: target)
        #expect(events.errors.isEmpty)
        #expect(events.result?.preview?.error?.contains("template missing") == true)
    }
}

// MARK: - WordPress and Symfony

@Suite(.serialized, .enabled(if: TestSupport.hasPHP && FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path),
                             "requires the WordPress fixture"))
struct WordPressInspectorTests {
    @Test func wpdbQueriesAreTimedThroughSaveQueries() async throws {
        let events = try await TestSupport.run("""
        $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->posts}");
        defined('SAVEQUERIES') && SAVEQUERIES
        """, target: DriverSupport.target(DriverSupport.fixture("wordpress")))
        #expect(events.result?.value?.scalar == "true", "\(events.errors)")
        let record = try #require(events.inspection.records(in: "Queries").last)
        #expect(record.query?.sql == "SELECT COUNT(*) FROM rl_posts")
        #expect(record.query?.timeMs != nil && record.query?.connection == "wpdb")
        #expect(record.snippetLine == 1)
    }
}

@Suite(.enabled(if: TestSupport.hasPHP && fixtureReady("symfony-app"), "requires the Symfony fixture"))
struct SymfonyInspectorTests {
    @Test func htmlResponsesHavePreviews() async throws {
        let events = try await TestSupport.run("""
        [new Symfony\\Component\\HttpFoundation\\JsonResponse(['a' => 1]), new Symfony\\Component\\HttpFoundation\\Response('<h1>Hi</h1>', 201, ['Content-Type' => 'text/html'])][1]
        """, target: DriverSupport.target(DriverSupport.fixture("symfony-app")))
        let preview = try #require(events.result?.preview, "\(events.errors)")
        #expect(preview.kind == "response" && preview.html == "<h1>Hi</h1>")
        #expect(preview.title == "Symfony\\Component\\HttpFoundation\\Response 201")
        let json = try await TestSupport.run("new Symfony\\Component\\HttpFoundation\\JsonResponse(['a' => 1])", target: DriverSupport.target(DriverSupport.fixture("symfony-app")))
        #expect(json.result?.preview == nil)
    }
}
