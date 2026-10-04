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

// MARK: - Snippet lines

/// Without a VarDumper (php -n skips php.ini tools such as global Ray), the runner defines
/// dump() and dd() with eval(). Frames inside that eval'd definition are not the snippet, so
/// a dump reports the snippet line that called it, not line 1.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SnippetLineTests {
    static let code = "$a = 1;\n\ndump($a);\nfunction_exists('dump') ? (new ReflectionFunction('dump'))->getFileName() : ''"

    static func check(_ frames: [(type: String, payload: [String: Any])]) {
        let dump = frames.first { $0.type == "dump" }?.payload
        #expect(dump?["inSnippet"] as? Bool == true)
        #expect(dump?["snippetLine"] as? Int == 3, "\(String(describing: dump))")
        // The fallback dump() really was the runner's own, evaluated code.
        let definedIn = ((frames.first { $0.type == "result" }?.payload["value"] as? [String: Any])?["scalar"] as? String) ?? ""
        #expect(definedIn.hasSuffix("eval()'d code"), "\(definedIn)")
    }

    @Test func fallbackDumpReportsTheCallingLine() throws {
        Self.check(try DriverSupport.rawFrames(Self.code, directory: DriverSupport.fixture("plain"), phpOptions: ["-n"]))
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func fallbackDumpReportsTheCallingLineOnPHP74() throws {
        Self.check(try DriverSupport.rawFrames(Self.code, directory: DriverSupport.fixture("plain"), php: TestSupport.herdPHP74!, phpOptions: ["-n"]))
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
        // Anonymous classes show without the file PHP appends to their name.
        #expect(events.result?.value?.className == "Illuminate\\Mail\\Mailable@anonymous")
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

// MARK: - WordPress mail (#192)

/// wp_mail() in the run inspector, and Intercept Mail through pre_wp_mail. No test sends mail:
/// every snippet starts with `mailSink`, and messages use made-up example.com/.test addresses.
enum WordPressMailSupport {
    /// The test mail sink: WordPress's PHPMailer is a subclass that keeps each message instead of
    /// sending it (or fails with `$fail`), and a guard on phpmailer_init makes wp_mail() throw
    /// when the sink isn't in place, so a mistake fails the test instead of sending mail.
    static let mailSink = """
    require_once ABSPATH . WPINC . '/PHPMailer/PHPMailer.php';
    require_once ABSPATH . WPINC . '/PHPMailer/Exception.php';
    class RunletTestMailSink extends PHPMailer\\PHPMailer\\PHPMailer {
        public static $messages = [];
        public static $fail = null;
        public function postSend() {
            if (self::$fail !== null) { throw new PHPMailer\\PHPMailer\\Exception(self::$fail); }
            self::$messages[] = $this->getSentMIMEMessage();
            return true;
        }
    }
    $GLOBALS['phpmailer'] = new RunletTestMailSink(true);
    $GLOBALS['phpmailerInits'] = 0;
    add_action('phpmailer_init', function ($mailer) {
        $GLOBALS['phpmailerInits']++;
        if (!$mailer instanceof RunletTestMailSink) { throw new RuntimeException('The test mail sink is not in place.'); }
    }, PHP_INT_MIN);

    """

    /// Lines `mailSink` adds before a snippet's own first line.
    static var sinkLines: Int { mailSink.split(separator: "\n", omittingEmptySubsequences: false).count - 1 }

    /// An HTML message with every header wp_mail() reads and a named attachment. The result:
    /// [wp_mail()'s answer, messages the sink got, phpmailer_init calls, the sink saw the subject].
    static let invoice = mailSink + """
    $file = sys_get_temp_dir() . '/runlet-invoice-' . uniqid() . '.txt';
    file_put_contents($file, str_repeat('x', 1234));
    $sent = wp_mail(['Ada <ada@example.com>', 'bob@example.com'], 'Your invoice', '<h1>Thanks</h1><p>Paid.</p>', ['Content-Type: text/html; charset=UTF-8', 'Cc: Grace <grace@example.test>', 'Bcc: audit@example.test', 'Reply-To: support@example.com', 'From: Shop <shop@example.com>'], ['invoice.txt' => $file]);
    unlink($file);
    [$sent, count(RunletTestMailSink::$messages), $GLOBALS['phpmailerInits'], strpos(RunletTestMailSink::$messages[0] ?? '', 'Subject: Your invoice') !== false]
    """

    static func checkInvoice(_ mail: MailRecord, intercepted: Bool) {
        #expect(mail.subject == "Your invoice")
        #expect(mail.mailer == "wp_mail")
        #expect(mail.from == [MailRecord.Address(address: "shop@example.com", name: "Shop")])
        #expect(mail.to == [MailRecord.Address(address: "ada@example.com", name: "Ada"), MailRecord.Address(address: "bob@example.com")])
        #expect(mail.cc == [MailRecord.Address(address: "grace@example.test", name: "Grace")])
        #expect(mail.bcc.map(\.address) == ["audit@example.test"])
        #expect(mail.replyTo.map(\.address) == ["support@example.com"])
        #expect(mail.html == "<h1>Thanks</h1><p>Paid.</p>" && mail.text == nil)
        #expect(mail.attachments.map(\.filename) == ["invoice.txt"])
        #expect(mail.attachments.first?.size == 1234)
        #expect(mail.attachments.first?.contentType == "text/plain")
        #expect(mail.intercepted == intercepted && !mail.queued && mail.error == nil)
        #expect(mail.caller == nil, "sent by the snippet itself")
    }

    static func scalars(_ events: [RunEvent]) -> [String?]? {
        events.result?.value?.entries?.map { $0.value.scalar }
    }

    /// Writes a must-use plugin into the fixture for one test; remove it with the returned URL.
    static func muPlugin(_ name: String, _ code: String) throws -> URL {
        let folder = TestSupport.fixtures.appendingPathComponent("wordpress/wp-content/mu-plugins")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try code.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

extension WordPressInspectorTests {
    var target: TargetSnapshot { DriverSupport.target(DriverSupport.fixture("wordpress")) }

    @Test func wpMailIsRecordedAndSentWhenInterceptionIsOff() async throws {
        let events = try await TestSupport.run(WordPressMailSupport.invoice, target: target)
        #expect(events.errors.isEmpty, "\(events.errors) \(events.stderr)")
        #expect(WordPressMailSupport.scalars(events) == ["true", "1", "1", "true"], "the sink received the message")
        let info = try #require(events.inspectorInfo)
        #expect(info.sections.contains("Mail"))
        #expect(!info.interceptMail && !info.interceptingMail)
        let record = try #require(events.inspection.records(in: "Mail").first)
        #expect(record.inSnippet == true && record.snippetLine == WordPressMailSupport.sinkLines + 3)
        WordPressMailSupport.checkInvoice(try #require(record.mail), intercepted: false)
    }

    @Test func interceptedWpMailIsRecordedAndNeverReachesPHPMailer() async throws {
        let events = try await TestSupport.run(WordPressMailSupport.invoice, target: target, inspector: RunInspectorOptions(interceptMail: true))
        #expect(events.errors.isEmpty, "\(events.errors) \(events.stderr)")
        // wp_mail() reports success, PHPMailer was never set up, and the sink stayed empty.
        #expect(WordPressMailSupport.scalars(events) == ["true", "0", "0", "false"])
        let info = try #require(events.inspectorInfo)
        #expect(info.interceptMail && info.interceptingMail && !info.interceptionUnsupported)
        #expect(info.interceptMailReason == nil)
        let mail = try #require(events.inspection.mails.first)
        WordPressMailSupport.checkInvoice(mail, intercepted: true)
        #expect(events.inspection.interceptedMailCount == 1)
    }

    @Test func coreMailNamesItsSenderAndFailuresCarryTheError() async throws {
        let events = try await TestSupport.run(WordPressMailSupport.mailSink + """
        add_filter('wp_mail_from', function ($from) { return $from === 'wordpress@localhost' ? 'wordpress@example.com' : $from; });
        wp_new_user_notification(1, null, 'admin');
        RunletTestMailSink::$fail = 'SMTP connect() failed.';
        $failed = wp_mail('ada@example.com', 'Will fail', 'Body');
        RunletTestMailSink::$fail = null;
        $invalid = wp_mail('ada@example.com', 'Bad sender', 'Body', 'From: not-an-address');
        [$failed, $invalid, count(RunletTestMailSink::$messages)]
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors) \(events.stderr)")
        #expect(WordPressMailSupport.scalars(events) == ["false", "false", "1"])
        let mails = events.inspection.mails
        #expect(mails.map(\.subject) == ["[Runlet WordPress Fixture] New User Registration", "Will fail", "Bad sender"])
        let notification = try #require(mails.first)
        #expect(notification.caller == "WordPress core: wp_new_user_notification()")
        #expect(notification.to.map(\.address) == ["runlet@example.test"])
        #expect(notification.from.first?.address == "wordpress@example.com")
        #expect(notification.text?.contains("New user registration") == true && notification.error == nil)
        // Failed while sending (after PHPMailer had the message), and before (an invalid sender).
        #expect(mails[1].error == "SMTP connect() failed." && mails[1].text == "Body" && !mails[1].intercepted)
        #expect(mails[2].error?.contains("Invalid address") == true && mails[2].from.first?.address == "not-an-address")
        #expect(events.inspection.records(in: "Mail").map(\.snippetLine) == [2, 4, 6].map { $0 + WordPressMailSupport.sinkLines })
    }

    /// The runner's WordPress mail code on PHP 7.4, the oldest PHP Runlet supports.
    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func wpMailOnPHP74() async throws {
        let target = DriverSupport.target(DriverSupport.fixture("wordpress"), php: TestSupport.herdPHP74!)
        let sent = try await TestSupport.run(WordPressMailSupport.invoice, target: target)
        #expect(sent.errors.isEmpty, "\(sent.errors) \(sent.stderr)")
        #expect(sent.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(WordPressMailSupport.scalars(sent) == ["true", "1", "1", "true"])
        WordPressMailSupport.checkInvoice(try #require(sent.inspection.mails.first), intercepted: false)
        let intercepted = try await TestSupport.run(WordPressMailSupport.invoice, target: target, inspector: RunInspectorOptions(interceptMail: true))
        #expect(WordPressMailSupport.scalars(intercepted) == ["true", "0", "0", "false"], "\(intercepted.errors)")
        WordPressMailSupport.checkInvoice(try #require(intercepted.inspection.mails.first), intercepted: true)
    }

    /// An SMTP plugin's own wp_mail() (WordPress keeps the first definition of a pluggable
    /// function) may skip pre_wp_mail: Runlet records what it can and says it can't stop it.
    @Test func aPluginThatReplacesWpMailDeclinesInterception() async throws {
        let plugin = try WordPressMailSupport.muPlugin("runlet-test-acme-smtp.php", """
        <?php
        // Runlet test fixture (#192): replaces wp_mail() and sends nothing.
        function wp_mail($to, $subject, $message, $headers = '', $attachments = array()) {
            $atts = apply_filters('wp_mail', compact('to', 'subject', 'message', 'headers', 'attachments'));
            $GLOBALS['acme_outbox'][] = $atts;
            return true;
        }
        """)
        defer { try? FileManager.default.removeItem(at: plugin) }
        let events = try await TestSupport.run(WordPressMailSupport.mailSink + """
        $sent = wp_mail('ada@example.com', 'Through Acme', 'Hello', 'From: Shop <shop@example.com>');
        [$sent, count($GLOBALS['acme_outbox'] ?? []), $GLOBALS['phpmailerInits']]
        """, target: target, inspector: RunInspectorOptions(interceptMail: true))
        #expect(events.errors.isEmpty, "\(events.errors) \(events.stderr)")
        #expect(WordPressMailSupport.scalars(events) == ["true", "1", "0"], "the plugin's wp_mail() handled it")
        let info = try #require(events.inspectorInfo)
        #expect(info.interceptMail && !info.interceptingMail && info.interceptionUnsupported)
        #expect(info.interceptMailReason == "A must-use plugin (runlet-test-acme-smtp.php) replaces wp_mail(); Runlet can't stop its mail.")
        let mail = try #require(events.inspection.mails.first)
        #expect(mail.subject == "Through Acme" && !mail.intercepted && mail.to.map(\.address) == ["ada@example.com"])
        #expect(events.inspection.records(in: "Mail").first?.snippetLine == WordPressMailSupport.sinkLines + 1)
    }

    /// Mail a plugin sends while WordPress boots is intercepted too: the hooks are in place
    /// before wp-load.php.
    @Test func mailSentWhileWordPressBootsIsIntercepted() async throws {
        let plugin = try WordPressMailSupport.muPlugin("runlet-test-boot-mail.php", """
        <?php
        add_action('init', function () { wp_mail('ops@example.test', 'Booted', 'Sent while WordPress boots', 'From: Ops <ops@example.com>'); });
        """)
        defer { try? FileManager.default.removeItem(at: plugin) }
        let events = try await TestSupport.run(WordPressMailSupport.mailSink + "count(RunletTestMailSink::$messages)", target: target, inspector: RunInspectorOptions(interceptMail: true))
        #expect(events.errors.isEmpty, "\(events.errors) \(events.stderr)")
        #expect(events.result?.value?.scalar == "0")
        #expect(events.inspectorInfo?.interceptingMail == true)
        let record = try #require(events.inspection.records(in: "Mail").first)
        let mail = try #require(record.mail)
        #expect(mail.subject == "Booted" && mail.intercepted)
        #expect(mail.caller == "must-use plugin runlet-test-boot-mail.php (line 2)")
        #expect(record.inSnippet == false && record.line == 2 && record.file?.hasSuffix("mu-plugins/runlet-test-boot-mail.php") == true)
    }

    /// Another pre_wp_mail callback could send a message itself (an API mailer that takes over
    /// there): Runlet still stops what reaches it, but doesn't promise interception.
    @Test func anotherPreWpMailCallbackMeansNoGuarantee() async throws {
        let plugin = try WordPressMailSupport.muPlugin("runlet-test-api-mailer.php", """
        <?php
        add_filter('pre_wp_mail', function ($return, $atts) {
            if ($atts['subject'] === 'Via API') { $GLOBALS['api_outbox'][] = $atts; return true; }
            return $return;
        }, 10, 2);
        """)
        defer { try? FileManager.default.removeItem(at: plugin) }
        let events = try await TestSupport.run(WordPressMailSupport.mailSink + """
        wp_mail('ada@example.com', 'Via API', 'Taken over', 'From: Shop <shop@example.com>');
        wp_mail('ada@example.com', 'Stopped', 'Intercepted', 'From: Shop <shop@example.com>');
        [count($GLOBALS['api_outbox'] ?? []), count(RunletTestMailSink::$messages)]
        """, target: target, inspector: RunInspectorOptions(interceptMail: true))
        #expect(events.errors.isEmpty, "\(events.errors) \(events.stderr)")
        #expect(WordPressMailSupport.scalars(events) == ["1", "0"])
        let info = try #require(events.inspectorInfo)
        #expect(!info.interceptingMail)
        #expect(info.interceptMailReason?.hasPrefix("A must-use plugin (runlet-test-api-mailer.php) filters pre_wp_mail") == true, "\(String(describing: info.interceptMailReason))")
        #expect(events.inspection.mails.map(\.subject) == ["Via API", "Stopped"])
        #expect(events.inspection.mails.map(\.intercepted) == [false, true])
    }
}

/// The same runner code on a Docker target: the `wordpress` runlet-fixtures service mounts the
/// WordPress fixture (scripts/setup-fixtures.sh docker).
@Suite(.serialized, .enabled(if: TestSupport.hasDocker && FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("wordpress/.runlet-fixture-ready").path),
                             "requires Docker and the WordPress fixture"))
struct WordPressMailDockerTests {
    func target() async throws -> TargetSnapshot {
        let docker = try #require(TestSupport.docker)
        let containers = try await docker.runningContainers()
        let container = try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == "wordpress" }, "start fixtures with scripts/setup-fixtures.sh docker")
        return TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: "/var/www/html", phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, temporaryDirectory: "/tmp")
    }

    @Test func wpMailIsRecordedAndInterceptedInAContainer() async throws {
        let target = try await target()
        let sent = try await TestSupport.run(WordPressMailSupport.invoice, target: target)
        #expect(sent.errors.isEmpty, "\(sent.errors) \(sent.stderr)")
        #expect(sent.started?.workingDirectory == "/var/www/html")
        #expect(WordPressMailSupport.scalars(sent) == ["true", "1", "1", "true"])
        WordPressMailSupport.checkInvoice(try #require(sent.inspection.mails.first), intercepted: false)

        let intercepted = try await TestSupport.run(WordPressMailSupport.invoice, target: target, inspector: RunInspectorOptions(interceptMail: true))
        #expect(intercepted.errors.isEmpty, "\(intercepted.errors) \(intercepted.stderr)")
        #expect(WordPressMailSupport.scalars(intercepted) == ["true", "0", "0", "false"])
        #expect(intercepted.inspectorInfo?.interceptingMail == true)
        WordPressMailSupport.checkInvoice(try #require(intercepted.inspection.mails.first), intercepted: true)
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
