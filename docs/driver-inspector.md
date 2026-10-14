# Run Inspector Hooks

Next to the output, the run inspector shows what a run did: the SQL statements it ran, the mail it sent, log messages, HTTP requests, jobs, events, rendered HTML, and sections your driver adds, such as "Cache" or "Payments". Drivers report all of it to one `Runlet\Inspector` per run. This page shows what's recorded without any code, and how a project driver adds more.

Runlet passes the inspector to your driver's `inspect(Inspector $inspector)` after `bootstrap()`, before the snippet runs. It never calls `inspect()` when it only lists commands. Turning the inspector off (**Settings ▸ General ▸ Run Inspector ▸ Record queries, mail, and logs**) records nothing, and `inspect()` isn't called.

## What Is Recorded Without Any Code

| Project | Queries | Mail | Log | How |
| --- | --- | --- | --- | --- |
| Laravel, Lumen, Laravel Zero | Yes | Yes, with [interception](#mail-interception) | Yes | The application's events: `QueryExecuted`, `MessageSending`, `MessageLogged`, and `JobQueued` for mail pushed to a queue. |
| Eloquent without Laravel (illuminate/database through Capsule, as in a Slim or PHP-DI app) | Yes | – | – | The connections Eloquent models use, or Capsule's global instance. |
| WordPress | Yes | `wp_mail()`, with [interception](#mail-interception) on 5.7+ | – | `$wpdb` with `SAVEQUERIES`, and WordPress's mail hooks ([WordPress Mail](#wordpress-mail)). |
| Symfony | Doctrine connections in the `doctrine` registry | Symfony Mailer, with interception on 6.3+ | – | DBAL logging, and `MessageEvent` on the event dispatcher. |
| Standalone Doctrine DBAL, plain PDO | With one line in your driver | – | – | `inspectDoctrine()`, `$inspector->watchPdo()`. |

Detection runs after your driver's `bootstrap()`, so a database layer set up there is found. It only looks at classes the application already loaded: it never autoloads anything to find out.

HTTP requests, jobs, and events are recorded without any code too; see [HTTP, Jobs, and Events](#http-jobs-and-events).

Your own `inspect()` replaces this detection. Call `parent::inspect($inspector)` to keep it, or leave the method empty to record nothing.

## Eloquent Without Laravel

A project driver that boots the app's container gets Eloquent's queries automatically:

```php
<?php
// .runlet/ShopDriver.php
use Runlet\Inspector;
use Shop\Cache;

class ShopDriver extends \Runlet\Driver
{
    private $container;

    public function bootstrap(string $projectPath): void
    {
        // Creates Capsule, calls setAsGlobal() and bootEloquent(), registers services.
        $this->container = require $projectPath . '/config/bootstrap.php';
    }

    public function variables(): array
    {
        return ['container' => $this->container];
    }

    public function inspect(Inspector $inspector): void
    {
        parent::inspect($inspector); // Eloquent through Capsule, found automatically

        // A Doctrine DBAL connection Runlet can't find on its own.
        $this->inspectDoctrine($inspector, $this->container->get('reports'), 'reports');

        // A section of your own.
        Cache::listen(static function (string $operation, string $key, $value) use ($inspector): void {
            $inspector->record('Cache', $operation . ' ' . $key, $value);
        });
    }
}
```

If the app creates its database layer lazily (a container factory that runs on first use), pass it explicitly: `$this->inspectEloquent($inspector, $this->container->get(Capsule::class))`. `inspectEloquent()` accepts a Capsule manager, a `DatabaseManager`, or one `Connection`.

How Eloquent queries are captured:

- **Live (the default).** Runlet listens for `QueryExecuted` on the connections' event dispatcher. When they have none (Capsule without `setEventDispatcher()`, the usual case) and `illuminate/events` is installed, Runlet creates a dispatcher for the run and binds it in Capsule's container, so connections opened later get it too. Model events stay off: Eloquent's own dispatcher isn't changed. Queries arrive as they run, with the snippet's line.
- **Query log (the fallback).** Without `illuminate/events`, Runlet turns on each connection's query log (creating the configured connections first, which opens nothing: PDO connects on first use). A query is reported when the next one starts and at the end of the run, so the list fills in a step behind. On Laravel 8 and later, queries still get their snippet line; on older versions they don't.

## Doctrine DBAL

```php
public function inspect(Inspector $inspector): void
{
    parent::inspect($inspector);
    $this->inspectDoctrine($inspector, $this->entityManager->getConnection(), 'default');
}
```

DBAL 2 and 3 get an SQL logger, chained to one the app already set. DBAL 4 gets a timing middleware around the connection's driver, or around the open driver connection when it's already connected. The Symfony driver does this for every connection in the `doctrine` registry.

## Plain PDO

PDO can't be hooked globally, so a driver (or a snippet) opts in per connection:

```php
public function inspect(Inspector $inspector): void
{
    $inspector->watchPdo($this->container->get(PDO::class), 'app');
}
```

`watchPdo()` installs a statement class that reports every `prepare()` and `execute()` with its bound values and time. It skips connections that already use their own statement class (as database layers often do) and persistent connections, and it can't see `PDO::query()` or `PDO::exec()`.

Built-in hooks tell the Queries section which database API ran a statement (Eloquent, Doctrine, WordPress, or PDO), so its [Explain action](sql-explain.md) can prepare a PHP tab that reaches the same connection. A statement you report yourself can say so too (`databaseAPI` in `$details`); without it, Explain prepares a PDO template that asks you to recreate the connection.

## HTTP, Jobs, and Events

The **HTTP**, **Jobs**, and **Events** sections record without any code on these projects:

| Project | HTTP | Jobs | Events |
| --- | --- | --- | --- |
| Laravel, Lumen, Laravel Zero | The `Http` client: Laravel 8.45 and later (`RequestSending`, `ResponseReceived`), failed connections from 8.48 (`ConnectionFailed`), with their error from 11.16 | Queued jobs from Laravel 8.24 (`JobQueued`; the queue and delay on the event from 11.0, else read from the job), and `JobQueueing` from 10.42; jobs run during the run (`JobProcessing`, `JobProcessed`, `JobFailed`, `JobExceptionOccurred`, `JobReleasedAfterException`) | Every dispatched event, when **Record events** is on |
| WordPress | `wp_remote_get()` and the rest of `WP_Http`, from `pre_http_request` to `http_api_debug` | – | – |
| Symfony | HttpClient's `http_client` service and scoped clients, with the profiler on: Symfony 4.4 and later, read from `TraceableHttpClient` at the end of the run | Messenger: messages sent to a transport (`SendMessageToTransportsEvent`, 4.3 and later), a `sync://` transport's handling, a worker's messages (`WorkerMessageReceivedEvent`, `WorkerMessageHandledEvent`, `WorkerMessageFailedEvent`), and, with the profiler on, messages a bus handled right away (`TraceableMessageBus`). See [Symfony](#symfony) for what each version adds. | – |
| Eloquent without Laravel, other projects | – | – | – |

A project driver can report its own requests and jobs ([below](#recording-from-your-driver)).

![The HTTP section of a Laravel run: a request Http::fake() answered, opened to show its redacted Authorization and X-Api-Key headers and its bodies, a faked 404, a request to a local server, and a failed connection](screenshots/run-inspector/http-light.webp#gh-light-mode-only)
![The HTTP section of a Laravel run: a request Http::fake() answered, opened to show its redacted Authorization and X-Api-Key headers and its bodies, a faked 404, a request to a local server, and a failed connection](screenshots/run-inspector/http-dark.webp#gh-dark-mode-only)

On an older Laravel, an event that doesn't exist yet is never fired: its section stays empty, and nothing else changes. The sections attach once the application booted, so requests and jobs while it boots aren't recorded, as with queries.

- **Faked responses.** A response from `Http::fake()` is marked **FAKED**: Runlet sees that the factory has fakes and that the response had no network transfer. In WordPress, a request another `pre_http_request` callback answered is marked faked.
- **Pairing and timing.** Each `RequestSending` is paired with its `ResponseReceived`, or with the `ConnectionFailed` for the same method and URL, and timed between them. A request with no answer by the end of the run is listed with an error.
- **Sync jobs.** A job that runs during the run is timed from `JobProcessing` to `JobProcessed` or `JobFailed`. Jobs on a connection with the `sync` driver are listed as they run, not as queued, and queued mail follows the same rule in **Mail**.
- **What a wrapper runs.** For `SendQueuedMailable`, `SendQueuedNotifications`, `CallQueuedListener`, `BroadcastEvent`, and `CallQueuedClosure`, the row shows the mailable, notification, listener, event, or `Closure`: read from the job's properties and Laravel's queue payload, so no code of yours runs.
- **Events.** A wildcard listener (`*`), registered after the application's own listeners, records each event's name and a summary of its payload, and returns nothing, so it can't stop an event. With it on, `Event::dispatch()` returns one more `null` in its list of listener responses.

### Symfony

Symfony's HttpClient fires no events, and its services can't be wrapped once the container is compiled without changing your application. Messenger fires events when it sends a message to a transport and when a worker handles one, but none when a bus handles a message right away. The Symfony profiler fills both gaps: with `framework.profiler` on (symfony/web-profiler-bundle turns it on in `dev`), Symfony wraps every HTTP client in a `TraceableHttpClient` and every bus in a `TraceableMessageBus`, which keep what went through them. Runlet only reads those lists, and only from services the application already created: it never calls, creates, or resets them.

- **When.** HTTP requests and Messenger messages are listed when the run ends: requests in the order they were sent, messages in the order they were dispatched. A worker resets the services after each message, which empties the profiler's lists, so Runlet reads them first.
- **Requests** show the headers the transport really sent (the scoped client's defaults and auth options included), read from the response's `debug` info, and have no snippet line: the trace doesn't say where a request came from. A refused connection is listed without its error, because the trace has no info for it. A response from `MockHttpClient` is marked faked. A client made with `HttpClient::create()` isn't traced, so it isn't listed.
- **Messages** are matched to the profiler's dispatches by the message object. A worker's or a `sync://` transport's redispatch of a message isn't listed again, and a failed message shows the handler's exception, unwrapped from `HandlerFailedException`.

What Messenger records depends on the Symfony version and the profiler:

| Symfony | Without the profiler | With the profiler |
| --- | --- | --- |
| 7.4 and later | Sent messages are **QUEUED** with their transport, delay, and the transport's message ID (`MessageSentToTransportsEvent`). A `sync://` message is timed; one whose handler threw is listed as **DIDN'T FINISH**. | Also: messages a bus handled right away (**PROCESSED** or **FAILED**, without a time), and a `sync://` message's exception. |
| 6.2 to 7.3 | Sent messages are **QUEUED** with their transport and delay, without the ID. A `sync://` message is **PROCESSED**, without a time, even when its handler threw. | Also: the message ID, a `sync://` message's exception, and messages a bus handled right away. |
| 4.4 to 6.1 | The event doesn't name the transports: every sent message is **QUEUED** without its transport, a `sync://` one too. | The transports and the ID, from the sent stamps, so `sync://` messages are told apart; and messages a bus handled right away. |

A worker's messages are listed the same way on every version: **PROCESSED**, **FAILED**, or **RELEASED** (`willRetry()`), with their time, receiver, and attempt.

### Recording From Your Driver

Report requests, jobs, and events from your own clients and queues with the same methods. Runlet redacts the credentials itself, and does nothing when the run doesn't record that section:

```php
public function inspect(Inspector $inspector): void
{
    parent::inspect($inspector);
    if (!$inspector->shouldRecord(Inspector::HTTP)) {
        return;
    }

    $this->container->get(ApiClient::class)->onResponse(function ($request, $response, float $ms) use ($inspector) {
        $inspector->http([
            'client' => 'ApiClient',
            'method' => $request->method,
            'url' => $request->url,
            'status' => $response->status,
            'durationMs' => $ms,
            'requestHeaders' => $request->headers,
            'responseHeaders' => $response->headers,
            // Kept only when the run records bodies.
            'responseBody' => $response->body,
        ]);
    });
}
```

## Custom Sections, Logs, and HTML

```php
public function inspect(Inspector $inspector): void
{
    parent::inspect($inspector);
    $inspector->section('Payments'); // shown even when the run makes none

    $this->container->get(PaymentGateway::class)->onCharge(function ($charge) use ($inspector) {
        $inspector->record('Payments', $charge->id . ' ' . $charge->currency, [
            'amount' => $charge->amount,
            'status' => $charge->status,
        ]);
    });
}
```

A snippet can report too: `\Runlet\Inspector::current()->record('Debug', 'cart', $cart)`. For a card in the output instead of a record, use `\Runlet\notice()`, `\Runlet\warning()`, or `\Runlet\error()` (also `$inspector->notice()`, `->warning()`, and `->error()`): they show the calling line and never fail the run, with the inspector on or off. See [the snippet API](snippet-api.md#notices-warnings-and-errors).

### Inspector Methods

| Method | Purpose |
| --- | --- |
| `query(string $sql, array $bindings = [], ?float $ms = null, ?string $connection = null, array $details = [])` | One statement in **Queries**. `$details`: `driver` (`mysql`, `pgsql`, `sqlite`, …), `rawSql` (the statement with the bindings your database layer substituted), `location` (from `location()`, for a statement reported after it ran), and `databaseAPI` (`eloquent`, `doctrine`, `wordpress`, or `pdo`). |
| `mail($message, array $details = [])` | One message in **Mail**: a Symfony Mime `Email`, a SwiftMailer message, or an array with `subject`, `from`, `to`, `cc`, `bcc`, `replyTo`, `html`, `text`, `attachments`, `mailer`, `mailable`, and `caller` (who sent it when that isn't the snippet, shown as **Sent by**). `$details` adds `intercepted`, `error` (why sending failed; the message shows as **Failed**), `queued`, `queueConnection`, and `location`. Inline `cid:` images become `data:` URLs. |
| `log(string $level, string $message, array $context = [], ?string $channel = null)` | One message in **Log**. |
| `html(string $title, string $html, string $section = 'HTML')` | Rendered HTML, previewed in a locked-down web view. |
| `record(string $section, string $title, $value)` | Any value in a section of your own, shown like a dump (bounded, and no methods are called except your driver's [casters](drivers.md#casters)). |
| `http(array $request)` | One request in **HTTP**: `method`, `url`, `status` (none when no response came), `reason`, `durationMs`, `requestHeaders` and `responseHeaders` (name => value or list of values), `requestBody` and `responseBody` (kept only when the run records bodies), `requestBodySize` and `responseBodySize`, `error`, `faked`, `client`, and `location`. Credentials are [redacted](run-inspector.md#credentials-are-redacted). |
| `job(array $job)` | One job in **Jobs**: `status` (`queued`, `processed`, `failed`, `released`, `unfinished`, `notQueued`), `class`, `name` (what a wrapper runs), `connection`, `queue`, `delay` (seconds), `id`, `uuid`, `attempts`, `durationMs`, `exception` (a `Throwable`, or `class` and `message`), and `location`. |
| `event(string $name, $payload = null, array $details = [])` | One event in **Events**, with a short summary of its payload. Only when the run records events. |
| `shouldRecord(string $section): bool`, `shouldRecordHttpBodies(): bool` | Whether the run records `Inspector::HTTP`, `Inspector::JOBS`, or `Inspector::EVENTS` (other sections follow `isEnabled()`), and HTTP bodies. Check them before attaching listeners you don't need. |
| `section(string $section)` | Shows a section even when nothing is recorded in it. |
| `watchPdo(\PDO $pdo, string $connection = 'pdo'): bool` | Records a PDO connection's prepared statements ([above](#plain-pdo)). |
| `shouldInterceptMail(): bool`, `interceptingMail()`, `cannotInterceptMail(string $reason)` | [Mail interception](#mail-interception). |
| `once(string $key): bool`, `atFinish(callable $callback)`, `location(): array` | Helpers for hooks: attach once, flush something when the run ends, and capture where the code running now came from. |
| `notice(string $message, array $context = [])`, `warning(…)`, `error(string\|\Throwable $message, array $context = [])` | A notice, warning, or non-fatal error card in the output, not a record. Shown with the inspector off too. |
| `Inspector::current()` | The run's inspector, or `null` outside a run. |

No method throws, so they're safe inside listeners. Each record carries the snippet line that caused it, or the first project file outside `vendor/`. If `inspect()` itself throws, Runlet shows a notice and the run continues.

## Mail Interception

**Intercept mail** (**Settings ▸ General ▸ Run Inspector**, off by default) asks drivers to record mail without sending it. Local projects, Docker profiles, and SSH profiles can override it in their **Mail** option. The output says which messages were intercepted, and the run's header says interception is on.

- **Laravel:** Runlet's `MessageSending` listener returns `false`, so Laravel builds the whole message (views, attachments) and then sends nothing. Notifications sent through the mail channel are covered too. Mail pushed to an asynchronous queue (`Mail::queue()`, or mailables that implement `ShouldQueue`, on a connection other than `sync`) is sent later by a queue worker, outside the run, so Runlet can't intercept it: it lists it as "queued" instead.
- **Symfony Mailer 6.3 and later:** `MessageEvent::reject()`. Older versions are recorded, not intercepted.
- **WordPress 5.7 and later:** Runlet's `pre_wp_mail` filter, the last one, answers for the message, so `wp_mail()` stops before PHPMailer and tells its caller the mail was sent. Runlet confirms interception only when it's guaranteed, and otherwise says why ([WordPress Mail](#wordpress-mail)).
- **Your driver:** check `$inspector->shouldInterceptMail()`, stop the message, record it with `['intercepted' => true]`, and call `$inspector->interceptingMail()` so Runlet knows. When interception is on and no driver confirms it, Runlet warns that mail is delivered normally. When your driver knows why it can't intercept, pass the reason to `$inspector->cannotInterceptMail($reason)`: the warning and the mail chip quote it.

Mail sent some other way (a raw SMTP client, or an HTTP API such as Mailgun's SDK) is neither recorded nor intercepted.

### WordPress Mail

With the run inspector on, the WordPress driver records every `wp_mail()` message: To, Cc, Bcc, From, Reply-To, the subject, the HTML or text body for the preview, attachments with their sizes, inline images as `data:` URLs, and **Sent by**: the plugin, must-use plugin, or theme that called `wp_mail()` (with its file and line), or the core function, such as `WordPress core: retrieve_password()`.

- A message that fails (`wp_mail_failed`, for example an invalid sender or an SMTP error) is listed as **Failed**, with PHPMailer's error.
- A sent message is recorded from what PHPMailer was given, after other plugins' `phpmailer_init` changes. An intercepted one never reaches PHPMailer, so it's recorded from `wp_mail()`'s arguments, read the way `wp_mail()` reads them (its headers, its defaults, and the `wp_mail_from`, `wp_mail_from_name`, and `wp_mail_content_type` filters).
- Runlet adds its hooks before WordPress loads, during its runs only, so mail a plugin sends while WordPress boots (on `init`, say) is covered too. **No file is added to your site:** a must-use plugin isn't needed, and would affect the site outside Runlet.

With **Intercept mail** on, Runlet confirms interception (in the run's header and the mail chip) only when it's guaranteed. Otherwise the warning says why, and each message shows what really happened to it:

- **WordPress before 5.7** has no `pre_wp_mail` filter: messages are recorded and sent.
- **A plugin or theme replaces `wp_mail()`** (some SMTP and email-API plugins define their own): "A plugin (acme-smtp) replaces wp_mail(); Runlet can't stop its mail." Runlet leaves that `wp_mail()` alone, and records what reaches the `wp_mail` filter and PHPMailer.
- **Another callback on `pre_wp_mail`** could send a message itself before Runlet's callback runs (an API mailer that takes over there). Runlet still stops each message that reaches its own callback unanswered, and marks it intercepted; a message another callback answered for is listed as sent.

Mailers that work inside `wp_mail()`, such as plugins that set PHPMailer up for SMTP or swap it for an HTTP API client, are stopped like any other message, because `pre_wp_mail` comes before PHPMailer. Mail that WP-Cron events or Action Scheduler jobs send later is sent outside the run, so Runlet neither records nor intercepts it (runs don't spawn WP-Cron), as with Laravel's queued mail.

### The Mail Chip

The output header of every PHP tab shows what runs on its target do with mail:

| Chip | Meaning |
| --- | --- |
| **Intercepting Mail** (orange) | Mail is recorded, not sent. Interception turns the inspector on for its runs. |
| **Sending Mail** (grey, or red on a production target) | Mail is sent. |
| **Mail: inspector off** (dimmed) | The run inspector is off: runs send mail and record nothing. |

![The Intercepting Mail chip of a production SSH target and its popover: why mail is intercepted, where that's set, and the Mail picker](screenshots/driver-inspector/mail-chip-light.webp#gh-light-mode-only)
![The Intercepting Mail chip of a production SSH target and its popover: why mail is intercepted, where that's set, and the Mail picker](screenshots/driver-inspector/mail-chip-dark.webp#gh-dark-mode-only)

Click the chip to see where the mode comes from ("Set in this target's options", or "Default, from Settings ▸ General ▸ Run Inspector"), and to change it with the same **Mail** picker as the target's settings: **Default**, **Intercept (record, don't send)**, or **Send**. The choice is saved in the target's settings and applies from the next run. The sandbox has no option of its own: its popover changes the default in Settings. **Open Settings…** opens Settings ▸ General, and with the inspector off, **Turn On Run Inspector** turns it on.

- Switching a production target that intercepts mail to sending (**Send**, or **Default** while Settings says Send) asks first, in the popover. Intercepting never asks.
- After a run on the target asked for interception, the popover says whether the driver confirmed it, or quotes the run's warning. Before such a run, it says nothing about support: that comes from what runs report, not from a list of drivers.
- SQL tabs don't show the chip: they run a statement, not the application's mail code.

## Previews

When a snippet returns or dumps an object that renders as HTML, the output shows it next to the value tree, in a web view with JavaScript off, no remote loads (images can be allowed per preview), and no navigation.

`Driver::preview($value)` decides. The default renders Laravel `Mailable`s (their HTML and text bodies, and subject), `MailMessage`s, a `Notification`'s `toMail()` (with an anonymous notifiable; return `$notification->toMail($user)` when it needs a real one), views, `Htmlable` and `Renderable` objects, and Symfony responses with HTML content. Rendering runs the application's view code, so its queries appear in the inspector; turn off **Preview returned mail, views, and HTML** in **Settings ▸ General ▸ Run Inspector** to skip it.

Override `preview()` to add your own types:

```php
public function preview($value): ?array
{
    if ($value instanceof \Acme\Pdf\Invoice) {
        return ['title' => 'Invoice ' . $value->number(), 'html' => $value->toHtml()];
    }

    return parent::preview($value);
}
```

## Benchmarks

`Runlet\bench()` measures code in any snippet, on every target (PHP 7.4 or later, with no extension), and shows a benchmark card where it ran, plus a **Benchmarks** section:

```php
Runlet\bench(fn () => Str::slug('Ada Lovelace'), 5000, 'Str::slug()');

Runlet\bench([
    'array_map' => fn () => array_map(fn ($x) => $x * 2, $items),
    'foreach' => function () use ($items) { /* … */ },
], 2000);
```

`bench($callables, int $iterations = 1000, ?string $label = null, ?float $seconds = null)` takes a callable, or an array of up to 20 callables keyed by label to compare side by side. It takes the same first two arguments as Laravel's `Benchmark::measure()`.

- **How it measures.** Each callable is called once cold (shown as "First call"), warmed up with up to 1% of the iterations (at most 10), then timed with `hrtime(true)` up to `$iterations` times. It stops at 100,000 timed calls per callable, or when the callable has used `$seconds` (1 second by default, at most 60); the card says how many calls ran. Garbage is collected once before the timed calls, not between them.
- **The card** shows the mean, median, p95, min, max, operations per second, the iterations, the standard deviation, the first call, and memory: the peak above what was in use before the timed calls, and the memory kept per call. (PHP 8.2 and later reset the peak for this; on older PHP, the peak shows only when it rose above the process's earlier peak.) Below them: a histogram of call times, from the fastest up to p99 or to the outlier fence (p75 + 3 × IQR) when that's lower, with median and p95 markers and the slower calls counted; and the mean per chunk of calls, in run order.
- **A comparison** shows each callable's mean as a bar, how many times slower it is than the fastest, and a table.
- **Short calls.** Timers tick in steps (41.67 ns on Apple silicon), so the histogram uses one bin per tick when the spread is that narrow, and the card says when calls are so short that the timer dominates.

`bench()` returns the numbers too, in milliseconds like Laravel's Benchmark: `mean_ms`, `median_ms`, `min_ms`, `max_ms`, `p95_ms`, `ops_per_sec`, `iterations`, `memory_peak_bytes`, and `memory_per_call_bytes` (keyed like `$callables` when it's an array of callables).

**Laravel's `Illuminate\Support\Benchmark`.** `Benchmark::dd()` is recognised from its dump: Runlet adds a benchmark card with the mean of each callable and the iteration count, and Laravel's own `dd()` output still shows. Laravel measures only the mean (to the microsecond), so that card has no distribution. `Benchmark::measure()` and `Benchmark::value()` return plain numbers and offer no hook, so swap `Benchmark::measure(` for `Runlet\bench(` to get the card.

Benchmarks and profiles are recorded even when the inspector is off: the snippet asked for them.

## Limits

Per run, Runlet records at most 2,000 statements, 2,000 other records, 8 MiB of record data in all, and 2 MiB per HTML or text body. Values in records are bounded more tightly than results: depth 6, 100 entries per level, 16 KiB per string, and 512 KiB per value. Within those, **HTTP** keeps 200 requests and 2 MiB, with 8 KB per body; **Jobs** keeps 500 jobs; and **Events** keeps 500 events and 1 MiB, with payloads 3 levels deep, 20 entries per level, and 512 bytes per string. What a limit leaves out is counted at the end of its section.

Hooks attach after the application boots, so queries the application runs while booting aren't recorded. On Lumen, the database and events are inspected only when the application resolved them while booting.

## For developers

- HTTP, Jobs, and Events ([#5](https://github.com/filipac/runlet/issues/5)): the listeners and the redaction are in `Resources/Runner/src/Recorders.php` (`HttpRecord`, `LaravelHttpRecorder`, `LaravelJobRecorder`, `LaravelEventRecorder`, `WordPressHttpRecorder`), attached by `LaravelDriver::inspectLaravelHttp()`, `inspectLaravelJobs()`, `inspectLaravelEvents()`, and `WordPressDriver::inspectWordPressHttp()`. Records: `kind` `http`, `job`, and `event`; a section's own cap reports `recordLimit` with `reason` `sectionCount` or `sectionBytes` and its `limit`. The request's `inspector` field adds `http`, `httpBodies`, `jobs`, and `events`, and the limits `maxHttpRequests`, `maxHttpBytes`, `maxHttpBodyBytes`, `maxJobs`, `maxEvents`, and `maxEventBytes`.
  - The minimum Laravel versions were checked against the framework's tags on GitHub: `RequestSending` and `ResponseReceived` first ship in v8.45.0, `ConnectionFailed` in v8.48.0 (its `$exception` in v11.16.0), `JobQueued` in v8.24.0 (`$payload` in v10.42.0, `$queue` and `$delay` in v11.0.0), and `JobQueueing` in v10.42.0. Laravel 13's `SyncQueue` fires no `JobQueueing` or `JobQueued`; Runlet skips them for sync connections anyway, in case a version does.
  - **Faked.** `Http::fake()` keeps its fakes in the factory's `stubCallbacks`; a faked response has no `TransferStats`, or (in newer versions, such as 13) ones with no transfer time and no handler stats. A real response through Guzzle's curl or stream handler always has a transfer time.
  - **Pairing.** `RequestSending` and `ResponseReceived` share the client's `Request` object; Laravel 13 wraps the failed request anew for `ConnectionFailed`, so that one is paired by method and URL, the latest first.
  - **Bodies** are read from the PSR-7 streams only when they're seekable, and their position is put back, so a streamed response is never consumed. Up to 64 KiB is read, so JSON can be pretty-printed before it's cut to 8 KiB.
  - **A dispatch on the last line.** The runner releases the snippet's result before the run finishes, so a `PendingDispatch` returned by the last line dispatches (and is recorded) inside the run.
  - **Symfony** ([#315](https://github.com/filipac/runlet/issues/315)): `SymfonyTraces`, `SymfonyHttpRecorder`, and `SymfonyMessengerRecorder` in `Recorders.php`, attached by `SymfonyDriver::inspectSymfonyHttp()` and `inspectSymfonyMessenger()`. `SymfonyDriver::createdServices()` finds the traceable decorators in the compiled container's `services` and `privates` arrays (`Symfony\Component\DependencyInjection\Container`), so nothing is instantiated; the HTTP decorators are private (`.debug.http_client`, `.debug.<scoped client>`), and `messenger.default_bus` is public. `SymfonyTraces` skips what the lists held at `inspect()`, reads them on `WorkerRunningEvent` and `WorkerStoppedEvent` at priority -1000, before `ResetServicesListener` resets the services at -1024 (`TraceableHttpClient` is tagged `kernel.reset`; `InMemoryTransport::reset()` empties its queue too), and marks the lists read again at -1100.
    - Versions, checked against Symfony's tags and CHANGELOGs: `SendMessageToTransportsEvent` and the `WorkerMessage*Event`s from v4.3.0, `getSenders()` on the first from v6.2.0, `MessageSentToTransportsEvent` from v7.4.0; `TraceableMessageBus` from v4.3.0 (`callTime`), with `stamps_after_dispatch` from v4.4.0 and a `disabled` closure (the profiler's state) from v7.3; `TraceableHttpClient` from v4.4.0, keeping the read `content` from v5.1.0. `WorkerRunningEvent`, on which a worker resets the services, is from v4.4.0. `HandlerFailedException::getWrappedExceptions()` from v6.4, `getNestedExceptions()` before. The recorders were run against Symfony 5.4, 6.4, and 8.1 apps with the fixture's messages (the 5.4 one with class-level handlers: `#[AsMessageHandler]` on methods needs 6.1).
    - **Decoration order.** Symfony 8.1 puts `TraceableHttpClient` innermost (decoration priority 100, inside `ScopingHttpClient`), so its options already have the scoped defaults; up to 8.0 it's outermost (priority 5), with the options as the caller passed them and a scoped client's URL maybe relative (Runlet then takes the response's absolute URL). Either way, the transport's `debug` info has the headers it sent: the curl and native clients log them after `> `. A refused connection never reports progress, so its trace has no info at all, not even the error.
    - **Matching.** Event entries and the profiler's dispatches are matched by the message object (`===`), and the entries hold their messages until the end of the run. `in-memory://` without serialization hands a worker the same object, so the worker's redispatch (it starts with a `ReceivedStamp`) is never taken for the send. A send that `MessageSentToTransportsEvent` never confirmed (7.4+) is **NOT QUEUED**, or **DIDN'T FINISH** for a `sync://` transport, unless the profiler's trace has its exception.
    - Tests: `SymfonyRunRecorderTests` on `Tests/Fixtures/symfony-app`, which `scripts/setup-fixtures.sh` gives Messenger, HttpClient, messages and handlers, an `in-memory://` (`async`) and a `sync://` (`now`) transport, a scoped client (`local.client`), a public `App\Service\Fetcher`, the profiler in `dev` and `test`, and `MockHttpClient` in `test` (marker `.runlet-inspector-ready`). Each test picks `dev`, `test`, or `prod` through a `php` wrapper that sets `APP_ENV`, and sends HTTP only to `LocalHTTPServer` and a closed local port.
  - Tests: `RunRecorderTests` (the Laravel fixture with `Http::fake()` and a `php -S` server on 127.0.0.1 it starts and stops, a closed local port, an in-memory database queue, older event shapes dispatched by name; the WordPress fixture's copy) and `RunRecorderCoreTests`.
- The inspector is `Resources/Runner/src/Inspector.php` (with the database hooks); benchmarks are `Benchmark.php` (`Runlet\bench()` and `Runlet\Benchmark`, [#41](https://github.com/filipac/runlet/issues/41)); profiles are `Profiler.php` ([Architecture ▸ Profile Run](architecture.md#profile-run)). Records: `kind` `benchmark` (section `Benchmarks`) and `profile` (section `Profile`); see [architecture.md](architecture.md). The request's `inspector` field carries `enabled`, `interceptMail`, and `previews`, and the limits `maxQueries`, `maxRecords`, `maxRecordBytes`, and `maxBodyBytes` ([Architecture ▸ Runner and transport](architecture.md#runner-and-transport)).
- The `Eloquent without Laravel` example is `Tests/Fixtures/eloquent-app/.runlet/ShopDriver.php`.
- The Explain action and the `databaseAPI` hint were added under [#4](https://github.com/filipac/runlet/issues/4); `notice()`, `warning()`, and `error()` under [#196](https://github.com/filipac/runlet/issues/196); WordPress mail recording and interception under [#192](https://github.com/filipac/runlet/issues/192) (hooks `wp_mail`, `pre_wp_mail`, `phpmailer_init`, `wp_mail_succeeded`, and `wp_mail_failed`; the class is `WordPressMail` in `Drivers.php`); the mail chip under [#193](https://github.com/filipac/runlet/issues/193) (`MailInterceptionPicker` is shared by the chip and the targets' editors).
- `Benchmark::dd()` is recognised by Runlet's dump handler, which sees `Benchmark::dd()` in the backtrace.
- This page was split out of `drivers.md` under [#289](https://github.com/filipac/runlet/issues/289); `drivers.md` keeps short sections with the old anchors (`#run-inspector`, `#mail-interception`, `#the-mail-chip`, `#previews`, `#benchmarks`).
