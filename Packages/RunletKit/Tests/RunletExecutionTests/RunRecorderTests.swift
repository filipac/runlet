import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// #5: the HTTP, Jobs, and Events sections. HTTP goes only to `Http::fake()`, WordPress's
/// `pre_http_request`, and a PHP server on 127.0.0.1 that each test starts and stops: never to
/// another host.

/// `php -S` on a free loopback port, answering with JSON (and a 404 for `/missing`).
final class LocalHTTPServer {
    let port: Int
    private let process: Process
    private let directory: URL

    init() throws {
        directory = try DriverSupport.temporaryDirectory("http-server")
        try #"""
        <?php
        $path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
        header('Content-Type: application/json');
        header('Set-Cookie: session=local-session-value; path=/; httponly');
        header('X-Request-Id: req-local');
        if ($path === '/missing') {
            http_response_code(404);
            echo json_encode(['error' => 'not found']);
            return;
        }
        echo json_encode(['ok' => true, 'path' => $path, 'method' => $_SERVER['REQUEST_METHOD'], 'access_token' => 'local-token-value']);
        """#.write(to: directory.appendingPathComponent("router.php"), atomically: true, encoding: .utf8)
        port = try SSHForwardPorts.pickFree()
        process = Process()
        process.executableURL = URL(fileURLWithPath: DriverSupport.php)
        process.arguments = ["-S", "127.0.0.1:\(port)", "router.php"]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !SSHForwardPorts.isListening(port) {
            guard Date() < deadline, process.isRunning else {
                stop()
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "php -S didn't start on 127.0.0.1:\(port)"])
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    var url: String { "http://127.0.0.1:\(port)" }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }
}

private func fixtureReady(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("\(name)/vendor/autoload.php").path)
}

private extension HTTPRecord {
    func header(_ name: String, response: Bool = false) -> HTTPRecord.Header? {
        (response ? responseHeaders : requestHeaders).first { $0.name.lowercased() == name.lowercased() }
    }
}

// MARK: - Laravel

@Suite(.serialized, .enabled(if: TestSupport.hasPHP && fixtureReady("laravel-app"), "requires scripts/setup-fixtures.sh"))
struct LaravelRunRecorderTests {
    var target: TargetSnapshot { DriverSupport.target(DriverSupport.fixture("laravel-app")) }

    // MARK: HTTP

    static let fakedRequest = #"""
    use Illuminate\Support\Facades\Http;

    Http::fake(['api.example.com/*' => Http::response(['id' => 7, 'access_token' => 'fake-token-value'], 201, ['Set-Cookie' => 'session=fake-session-value; path=/', 'X-Api-Key' => 'fake-key-value'])]);
    $response = Http::withToken('example-token')
        ->withHeaders(['Cookie' => 'theme=dark; session=cookie-value', 'X-Api-Key' => 'header-key-value', 'Accept-Language' => 'en'])
        ->post('https://user:pass-value@api.example.com/v1/orders?api_key=query-key-value&page=2&signature=sig-value', ['password' => 'body-password-value', 'name' => 'Ada']);
    $response->status()
    """#

    @Test func fakedRequestsAreRecordedWithRedactedHeadersAndQuery() async throws {
        let events = try await TestSupport.run(Self.fakedRequest, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "201", "the fake answered")
        let inspection = events.inspection
        #expect(inspection.sections.contains("HTTP"))
        let record = try #require(inspection.records(in: "HTTP").first)
        #expect(record.inSnippet == true && record.snippetLine == 6, "the line that sent it: \(String(describing: record.snippetLine))")
        let http = try #require(record.http)
        #expect(http.method == "POST")
        #expect(http.url == "https://user:[redacted]@api.example.com/v1/orders?api_key=[redacted]&page=2&signature=[redacted]", "\(http.url)")
        #expect(http.status == 201 && http.faked && http.client == "Laravel")
        #expect(http.durationMs != nil)
        #expect(http.header("Authorization")?.value == "Bearer [redacted]")
        #expect(http.header("Authorization")?.redacted == true)
        #expect(http.header("Cookie")?.value == "theme=[redacted]; session=[redacted]")
        #expect(http.header("X-Api-Key")?.value == "[redacted]")
        #expect(http.header("Accept-Language")?.value == "en" && http.header("Accept-Language")?.redacted == false)
        #expect(http.header("Set-Cookie", response: true)?.value == "session=[redacted]; path=/")
        #expect(http.header("X-Api-Key", response: true)?.value == "[redacted]")
        // Bodies are off by default: only their sizes.
        #expect(http.requestBody == nil && http.responseBody == nil)
        #expect((http.responseBodySize ?? 0) > 0 && (http.requestBodySize ?? 0) > 0)
        // Nothing secret anywhere in what reached the app.
        let everything = "\(http)"
        for secret in ["example-token", "cookie-value", "header-key-value", "query-key-value", "sig-value", "pass-value", "fake-session-value", "fake-key-value", "fake-token-value", "body-password-value"] {
            #expect(!everything.contains(secret), "\(secret) leaked")
        }
    }

    @Test func bodiesAreKeptOnlyWhenAskedForCappedAndRedacted() async throws {
        let events = try await TestSupport.run(#"""
        use Illuminate\Support\Facades\Http;

        Http::fake([
            'api.example.com/v1/orders' => Http::response(['id' => 7, 'access_token' => 'response-token-value', 'items' => [['sku' => 'A-1', 'qty' => 2]]], 201),
            'api.example.com/v1/export' => Http::response(str_repeat('x', 20000), 200, ['Content-Type' => 'text/plain']),
        ]);
        Http::post('https://api.example.com/v1/orders', ['customer' => 'Ada', 'password' => 'request-password-value']);
        Http::asForm()->post('https://api.example.com/v1/orders', ['client_secret' => 'form-secret-value', 'grant_type' => 'client_credentials']);
        Http::get('https://api.example.com/v1/export');
        """#, target: target, inspector: RunInspectorOptions(httpBodies: true))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let requests = events.inspection.httpRequests
        #expect(requests.count == 3)

        let json = try #require(requests.first)
        #expect(json.requestBodyFormat == "json" && json.responseBodyFormat == "json")
        #expect(json.requestBody == "{\n    \"customer\": \"Ada\",\n    \"password\": \"[redacted]\"\n}", "\(json.requestBody ?? "nil")")
        #expect(json.responseBody?.contains("\"access_token\": \"[redacted]\"") == true)
        #expect(json.responseBody?.contains("\"sku\": \"A-1\"") == true, "pretty-printed JSON: \(json.responseBody ?? "nil")")

        let form = requests[1]
        #expect(form.requestBodyFormat == "form")
        #expect(form.requestBody == "client_secret=[redacted]&grant_type=client_credentials", "\(form.requestBody ?? "nil")")

        let export = requests[2]
        #expect(export.responseBody?.utf8.count == 8192, "capped at 8 KiB")
        #expect(export.responseBodyOmittedBytes == 20000 - 8192)
        #expect(export.responseBodySize == 20000)

        let everything = "\(requests)"
        for secret in ["response-token-value", "request-password-value", "form-secret-value"] {
            #expect(!everything.contains(secret), "\(secret) leaked")
        }
    }

    @Test func localServerRoundTripsAreTimedAndConnectionFailuresRecorded() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let closed = try SSHForwardPorts.pickFree()
        let events = try await TestSupport.run(#"""
        use Illuminate\Support\Facades\Http;

        Http::fake(['api.example.com/*' => Http::response(['faked' => true])]);
        $ok = Http::get('\#(server.url)/v1/ping?token=local-query-token');
        $missing = Http::get('\#(server.url)/missing');
        try {
            Http::connectTimeout(2)->get('http://127.0.0.1:\#(closed)/closed?token=closed-token-value');
        } catch (\Illuminate\Http\Client\ConnectionException $e) {
        }
        Http::get('https://api.example.com/v1/faked');
        [$ok->status(), $ok->json('ok'), $missing->status()]
        """#, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.entries?.map(\.value.scalar) == ["200", "true", "404"], "\(String(describing: events.result?.value))")
        let requests = events.inspection.httpRequests
        #expect(requests.count == 4, "\(requests.map(\.summary))")

        let ok = requests[0]
        #expect(ok.url == "\(server.url)/v1/ping?token=[redacted]")
        #expect(ok.status == 200 && !ok.faked, "a real round trip to 127.0.0.1")
        #expect((ok.durationMs ?? 0) > 0)
        #expect(ok.header("X-Request-Id", response: true)?.value == "req-local")
        #expect(ok.header("Set-Cookie", response: true)?.value == "session=[redacted]; path=/; httponly")

        let missing = requests[1]
        #expect(missing.status == 404 && missing.outcome == .clientError && missing.isFailure)

        let failed = requests[2]
        #expect(failed.status == nil && failed.outcome == .failed)
        #expect(failed.error?.contains("cURL error 7") == true, "\(failed.error ?? "nil")")
        #expect(failed.durationMs != nil, "paired with its RequestSending")
        #expect(failed.url == "http://127.0.0.1:\(closed)/closed?token=[redacted]")
        #expect(!"\(failed)".contains("closed-token-value"))

        #expect(requests[3].faked && requests[3].status == 200)
        #expect(events.inspection.failedHTTPCount == 2)
    }

    @Test func httpCanBeTurnedOffAndIsCapped() async throws {
        let code = #"""
        use Illuminate\Support\Facades\Http;

        Http::fake();
        foreach (range(1, 5) as $page) {
            Http::get('https://api.example.com/v1/items', ['page' => $page]);
        }
        """#
        let off = try await TestSupport.run(code, target: target, inspector: RunInspectorOptions(http: false))
        #expect(off.errors.isEmpty, "\(off.errors)")
        #expect(!off.inspection.sections.contains("HTTP"))

        var limits = RunLimits()
        limits.maxHttpRequests = 3
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, limits: limits)
        let capped = try await TestSupport.run(code, target: target, engine: engine)
        #expect(capped.inspection.httpRequests.count == 3)
        #expect(capped.inspection.omitted(in: "HTTP") == RecordLimitInfo(section: "HTTP", omitted: 2, reason: "sectionCount", limit: 3))
    }

    // MARK: Jobs

    static let jobClasses = #"""
    use Illuminate\Bus\Queueable;
    use Illuminate\Contracts\Queue\ShouldQueue;
    use Illuminate\Foundation\Bus\Dispatchable;
    use Illuminate\Queue\InteractsWithQueue;
    use Illuminate\Queue\SerializesModels;

    class SendInvoice implements ShouldQueue
    {
        use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

        public function __construct(public int $order) {}

        public function handle(): void
        {
            usleep(2000);
        }
    }

    class ChargeCard implements ShouldQueue
    {
        use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

        public function handle(): void
        {
            throw new RuntimeException('Card declined');
        }
    }

    class WelcomeMail extends Illuminate\Mail\Mailable
    {
        use Queueable;

        public function build()
        {
            return $this->subject('Welcome')->html('<p>Hi</p>');
        }
    }
    """#

    @Test func syncJobsAreRecordedAsTheyRunWithTheirTimeAndException() async throws {
        let events = try await TestSupport.run(Self.jobClasses + "\n" + #"""
        SendInvoice::dispatch(42);
        config(['mail.default' => 'array']);
        Illuminate\Support\Facades\Mail::to('ada@example.com')->queue(new WelcomeMail());
        try {
            ChargeCard::dispatch();
        } catch (RuntimeException $e) {
        }
        'done'
        """#, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let jobs = events.inspection.jobs
        #expect(jobs.map(\.status) == [.processed, .processed, .failed], "\(jobs.map(\.summary))")
        try #require(jobs.count == 3)

        let invoice = jobs[0]
        #expect(invoice.class == "SendInvoice" && invoice.name == nil)
        #expect(invoice.connection == "sync")
        #expect((invoice.durationMs ?? 0) >= 2, "usleep(2000) in handle()")
        #expect(invoice.uuid != nil)
        #expect(events.inspection.records(in: "Jobs").first?.snippetLine == 38)

        // Queued mail on the sync connection is sent during the run: a job here, sent mail in Mail.
        #expect(jobs[1].class == "Illuminate\\Mail\\SendQueuedMailable" && jobs[1].name == "WelcomeMail")
        let mail = try #require(events.inspection.mails.first)
        #expect(!mail.queued && mail.subject == "Welcome")

        let charge = jobs[2]
        #expect(charge.class == "ChargeCard")
        #expect(charge.exception == JobRecord.Exception(class: "RuntimeException", message: "Card declined"))
        #expect(events.inspection.failedJobCount == 1)
    }

    @Test func queuedJobsAndQueuedMailAgree() async throws {
        let events = try await TestSupport.run(Self.jobClasses + "\n" + #"""
        use Illuminate\Support\Facades\Mail;
        use Illuminate\Support\Facades\Schema;

        // A database queue in memory, so nothing touches the fixture's database.
        config(['database.connections.memory' => ['driver' => 'sqlite', 'database' => ':memory:', 'prefix' => '']]);
        Schema::connection('memory')->create('jobs', function ($table) {
            $table->id();
            $table->string('queue')->index();
            $table->longText('payload');
            $table->unsignedTinyInteger('attempts');
            $table->unsignedInteger('reserved_at')->nullable();
            $table->unsignedInteger('available_at');
            $table->unsignedInteger('created_at');
        });
        config(['queue.connections.later' => ['driver' => 'database', 'connection' => 'memory', 'table' => 'jobs', 'queue' => 'default', 'retry_after' => 90]]);
        config(['mail.default' => 'array']);

        SendInvoice::dispatch(7)->onConnection('later')->onQueue('billing')->delay(60);
        Mail::to('ada@example.com')->queue((new WelcomeMail())->onConnection('later'));
        DB::connection('memory')->table('jobs')->count()
        """#, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "2")
        let jobs = events.inspection.jobs
        #expect(jobs.count == 2, "\(jobs.map(\.summary))")
        try #require(jobs.count == 2)

        let invoice = try #require(jobs.first)
        #expect(invoice.status == .queued && invoice.class == "SendInvoice")
        #expect(invoice.connection == "later" && invoice.queue == "billing")
        #expect(invoice.delay == 60 || invoice.delay == 59, "\(String(describing: invoice.delay))")
        #expect(invoice.id == "1")

        let mailJob = jobs[1]
        #expect(mailJob.status == .queued && mailJob.class == "Illuminate\\Mail\\SendQueuedMailable")
        #expect(mailJob.name == "WelcomeMail")
        #expect(mailJob.wrapper == "Illuminate\\Mail\\SendQueuedMailable")
        // The Mail section lists the same message as queued, on the same connection.
        let mail = try #require(events.inspection.mails.first)
        #expect(mail.queued && mail.queueConnection == "later" && mail.mailable == mailJob.name)
    }

    @Test func olderEventShapesDegradeCleanly() async throws {
        // Laravel 8.24 to 10.41: JobQueued without queue, delay, or payload. Laravel 8.48 to
        // 11.15: ConnectionFailed without its exception. Dispatched by name, with stand-ins.
        let events = try await TestSupport.run(Self.jobClasses + "\n" + #"""
        use Illuminate\Http\Client\Request;
        use GuzzleHttp\Psr7\Request as PsrRequest;

        $job = (new SendInvoice(9))->onQueue('mail')->delay(30);
        event('Illuminate\Queue\Events\JobQueued', [(object) ['connectionName' => 'redis', 'id' => 'abc-1', 'job' => $job]]);
        $request = new Request(new PsrRequest('GET', 'https://api.example.com/v1/old?key=old-key-value'));
        event('Illuminate\Http\Client\Events\RequestSending', [(object) ['request' => $request]]);
        event('Illuminate\Http\Client\Events\ConnectionFailed', [(object) ['request' => $request]]);
        'done'
        """#, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let job = try #require(events.inspection.jobs.first)
        #expect(job.status == .queued && job.class == "SendInvoice" && job.connection == "redis")
        #expect(job.id == "abc-1" && job.queue == "mail", "the queue from the job itself")
        #expect(job.delay == 30 || job.delay == 29)
        let http = try #require(events.inspection.httpRequests.first)
        #expect(http.status == nil && http.error == "The connection failed: no response.")
        #expect(http.url == "https://api.example.com/v1/old?key=[redacted]")
        #expect(events.notices.isEmpty, "\(events.notices)")
    }

    @Test func jobsCanBeTurnedOff() async throws {
        let events = try await TestSupport.run(Self.jobClasses + "\nSendInvoice::dispatch(1);", target: target, inspector: RunInspectorOptions(jobs: false))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(!events.inspection.sections.contains("Jobs"))
    }

    // MARK: Events

    static let eventCode = #"""
    use App\Models\Widget;
    use Illuminate\Support\Facades\Event;
    use Illuminate\Support\Facades\Log;

    class OrderShipped
    {
        public function __construct(public int $order, public string $carrier) {}
    }

    Widget::query()->first();
    Log::info('Shipping');
    event(new OrderShipped(42, 'Example Post'));
    Event::dispatch('cart.updated', [['items' => 3]]);
    [Event::until('nobody.listens'), Event::dispatch('order.audit', [], true)]
    """#

    @Test func eventsAreOffByDefault() async throws {
        let events = try await TestSupport.run(Self.eventCode, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(!events.inspection.sections.contains("Events"))
        #expect(events.inspection.records(in: "Events").isEmpty)
    }

    @Test func eventsOnRecordTheAppsEventsAndLeaveOutTheRest() async throws {
        let events = try await TestSupport.run(Self.eventCode, target: target, inspector: RunInspectorOptions(events: true))
        #expect(events.errors.isEmpty, "\(events.errors)")
        // The listener returns nothing: until() and a halting dispatch still find no answer.
        #expect(events.result?.value?.entries?.map(\.value.type) == [.null, .null], "\(String(describing: events.result?.value))")
        let inspection = events.inspection
        #expect(inspection.sections.contains("Events"))
        let names = inspection.events(matching: "").map(\.event.name)
        #expect(names == ["OrderShipped", "cart.updated", "nobody.listens", "order.audit"], "\(names)")
        let shipped = try #require(inspection.events(matching: "shipped").first)
        #expect(shipped.record.snippetLine == 12)
        #expect(shipped.event.payload?.className == "OrderShipped")
        #expect(shipped.event.payload?.entries?.map(\.key) == ["order", "carrier"], "\(String(describing: shipped.event.payload))")
        let cart = try #require(inspection.events(matching: "cart").first)
        #expect(cart.event.payload?.entries?.first?.key == "items")
        // Queries and logs have their own sections.
        #expect(!names.contains { $0.contains("QueryExecuted") || $0.contains("MessageLogged") || $0.hasPrefix("eloquent.") })
        #expect(inspection.queries.count >= 1 && !inspection.records(in: "Log").isEmpty)
    }

    @Test func eventsAreCapped() async throws {
        var limits = RunLimits()
        limits.maxEvents = 3
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, limits: limits)
        let events = try await TestSupport.run("foreach (range(1, 10) as $i) { event('tick.' . $i, [$i]); }", target: target, engine: engine, inspector: RunInspectorOptions(events: true))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.inspection.records(in: "Events").count == 3)
        #expect(events.inspection.omitted(in: "Events") == RecordLimitInfo(section: "Events", omitted: 7, reason: "sectionCount", limit: 3))
    }
}

private extension Array where Element == RunEvent {
    var notices: [String] {
        compactMap { if case .notice(let message) = $0.kind { return message } else { return nil } }
    }
}

// MARK: - WordPress

@Suite(.serialized, .enabled(if: TestSupport.hasPHP && TestSupport.hasWordPressFixture, "requires the WordPress fixture (scripts/setup-fixtures.sh)"))
struct WordPressRunRecorderTests {
    @Test func wpRemoteRequestsAreRecordedAndAnsweredOnesMarkedFaked() async throws {
        let site = try DriverSupport.temporaryDirectory("wp-http")
        try FileManager.default.removeItem(at: site)
        try TestSupport.cloneWordPressFixture(to: site)
        defer { try? FileManager.default.removeItem(at: site) }
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let events = try await TestSupport.run(#"""
        add_filter('pre_http_request', function ($preempt, $args, $url) {
            if (strpos($url, 'https://api.example.com/') !== 0) {
                return $preempt;
            }

            return ['headers' => ['content-type' => 'application/json'], 'body' => '{"ok":true}', 'response' => ['code' => 202, 'message' => 'Accepted'], 'cookies' => []];
        }, 10, 3);
        $faked = wp_remote_post('https://api.example.com/v1/hooks?token=wp-query-token', ['headers' => ['Authorization' => 'Basic wp-basic-value'], 'body' => ['password' => 'wp-body-password']]);
        $real = wp_remote_get('\#(server.url)/v1/ping');
        [wp_remote_retrieve_response_code($faked), wp_remote_retrieve_response_code($real)]
        """#, target: DriverSupport.target(site.path), inspector: RunInspectorOptions(httpBodies: true))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.entries?.map(\.value.scalar) == ["202", "200"], "\(String(describing: events.result?.value))")
        let requests = events.inspection.httpRequests
        #expect(requests.count == 2, "\(requests.map(\.summary))")

        let faked = requests[0]
        #expect(faked.client == "WordPress" && faked.faked && faked.method == "POST" && faked.status == 202)
        #expect(faked.url == "https://api.example.com/v1/hooks?token=[redacted]")
        #expect(faked.header("Authorization")?.value == "Basic [redacted]")
        #expect(faked.requestBody == "password=[redacted]", "\(faked.requestBody ?? "nil")")

        let real = requests[1]
        #expect(!real.faked && real.status == 200 && real.reason == "OK")
        #expect((real.durationMs ?? 0) > 0)
        #expect(real.header("set-cookie", response: true)?.value == "session=[redacted]; path=/; httponly")
        #expect(real.responseBody?.contains("\"access_token\": \"[redacted]\"") == true, "\(real.responseBody ?? "nil")")
        #expect(real.header("User-Agent")?.value.hasPrefix("WordPress/") == true)

        let everything = "\(requests)"
        for secret in ["wp-query-token", "wp-basic-value", "wp-body-password", "local-session-value", "local-token-value"] {
            #expect(!everything.contains(secret), "\(secret) leaked")
        }
    }
}
