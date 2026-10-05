# Run Inspector Hooks

Next to the output, the run inspector shows what a run did: the SQL statements it ran, the mail it sent, log messages, rendered HTML, and sections your driver adds, such as "Cache", "HTTP calls", or "Events". Drivers report all of it to one `Runlet\Inspector` per run. This page shows what's recorded without any code, and how a project driver adds more.

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

## Custom Sections, Logs, and HTML

```php
public function inspect(Inspector $inspector): void
{
    parent::inspect($inspector);
    $inspector->section('HTTP calls'); // shown even when the run makes none

    $this->container->get(HttpClient::class)->onResponse(function ($request, $response) use ($inspector) {
        $inspector->record('HTTP calls', $request->method() . ' ' . $request->url(), [
            'status' => $response->status(),
            'body' => $response->body(),
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
| `record(string $section, string $title, $value)` | Any value in a section of your own, shown like a dump (bounded, and no methods are called). |
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

<!-- screenshot: the output header's mail chip and its popover with the Mail picker, on a production target that intercepts mail -->

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

**Laravel's `Benchmark`.** `Benchmark::dd()` is recognised from its dump: Runlet adds a benchmark card with the mean of each callable and the iteration count, and Laravel's own `dd()` output still shows. Laravel measures only the mean (to the microsecond), so that card has no distribution. `Benchmark::measure()` and `Benchmark::value()` return plain numbers and offer no hook, so swap `Benchmark::measure(` for `Runlet\bench(` to get the card.

Benchmarks and profiles are recorded even when the inspector is off: the snippet asked for them.

## Limits

Per run, Runlet records at most 2,000 statements, 2,000 other records, 8 MiB of record data in all, and 2 MiB per HTML or text body. Values in records are bounded more tightly than results: depth 6, 100 entries per level, 16 KiB per string, and 512 KiB per value. What a limit leaves out is counted at the end of its section.

Hooks attach after the application boots, so queries the application runs while booting aren't recorded. On Lumen, the database and events are inspected only when the application resolved them while booting.

## For developers

- The inspector is `Resources/Runner/src/Inspector.php` (with the database hooks); benchmarks are `Benchmark.php` (`Runlet\bench()` and `Runlet\Benchmark`, [#41](https://github.com/filipac/runlet/issues/41)); profiles are `Profiler.php` ([Architecture ▸ Profile Run](architecture.md#profile-run)). Records: `kind` `benchmark` (section `Benchmarks`) and `profile` (section `Profile`); see [architecture.md](architecture.md). The request's `inspector` field carries `enabled`, `interceptMail`, and `previews`, and the limits `maxQueries`, `maxRecords`, `maxRecordBytes`, and `maxBodyBytes` ([Architecture ▸ Runner and transport](architecture.md#runner-and-transport)).
- The `Eloquent without Laravel` example is `Tests/Fixtures/eloquent-app/.runlet/ShopDriver.php`.
- The Explain action and the `databaseAPI` hint were added under [#4](https://github.com/filipac/runlet/issues/4); `notice()`, `warning()`, and `error()` under [#196](https://github.com/filipac/runlet/issues/196); WordPress mail recording and interception under [#192](https://github.com/filipac/runlet/issues/192) (hooks `wp_mail`, `pre_wp_mail`, `phpmailer_init`, `wp_mail_succeeded`, and `wp_mail_failed`; the class is `WordPressMail` in `Drivers.php`); the mail chip under [#193](https://github.com/filipac/runlet/issues/193) (`MailInterceptionPicker` is shared by the chip and the targets' editors).
- `Benchmark::dd()` is recognised by Runlet's dump handler, which sees `Benchmark::dd()` in the backtrace.
- This page was split out of `drivers.md` under [#289](https://github.com/filipac/runlet/issues/289); `drivers.md` keeps short sections with the old anchors (`#run-inspector`, `#mail-interception`, `#the-mail-chip`, `#previews`, `#benchmarks`).
