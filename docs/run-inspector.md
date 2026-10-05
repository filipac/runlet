# Run Inspector

Running PHP is half of it. Every run shows what happened, in the output pane next to your code: what the snippet printed and returned, its errors, the SQL it sent, the mail it sent, the logs it wrote, the HTTP requests it made, the jobs it queued or ran, and anything your project's driver records. Think of it as Telescope for one run, without installing Telescope.

For example, in a Laravel project:

```php
use App\Models\Order;

Order::query()
    ->where('status', 'pending')
    ->latest()
    ->take(10)
    ->get(); //?
```

The `//?` line shows the collection. **Queries** shows the `select` with its bindings and time, and its **Explain** button opens the plan request in a new tab.

![The Queries section after a run in the sandbox: six statements with their times, connection, and snippet line, and the N+1 and repeated-statement hints](screenshots/run-inspector/queries-light.webp#gh-light-mode-only)
![The Queries section after a run in the sandbox: six statements with their times, connection, and snippet line, and the N+1 and repeated-statement hints](screenshots/run-inspector/queries-dark.webp#gh-dark-mode-only)

## The Output Pane

Above the output, a bar lists **Output** and the run's sections, with their counts: **Queries**, **Mail**, and **Log** for what the project's framework records, then **HTTP**, **Jobs**, **Events**, **HTML**, **Benchmarks**, **Profile**, and the sections a driver adds, once the run records something in them. Click one to show it in place of the output.

- An orange triangle on **Queries** means the run repeated a statement: a possible N+1 or duplicate query.
- An envelope on **Mail** means messages were intercepted, not sent.
- An orange triangle on **HTTP** or **Jobs** means a request or a job failed.
- **Run ▸ Show Queries**, **Show Mail**, **Show HTTP Requests**, **Show Jobs**, and **Show Events** (also in the command palette) open those sections. **Settings ▸ Shortcuts** can give them shortcuts.

The output itself has three views. Switch them in the pane's header, or in the **Run** menu:

| View | Shortcut | Shows |
| --- | --- | --- |
| **Structured** | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>1</kbd> | Cards: printed output, dumps, the result as a tree or a table, and error cards. |
| **Plain** | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>2</kbd> | A transcript, as a command line would show it. |
| **Raw** | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>3</kbd> | Exactly what PHP wrote to its output and error streams. |

Output appears while the code runs. To see a run's output all at once when it ends, choose **At once** in **Settings ▸ General ▸ Output**.

## What a Run Shows

| In your snippet | In the output |
| --- | --- |
| The last expression, or `return` | A **Result** card: an expandable tree, a sortable table for rows and collections, and viewers for strings that hold [JSON, long text, images, or HTML](string-viewers.md). |
| `echo`, `print`, `printf` | Printed output, as written. Output to the error stream is orange. |
| `dump()`, `dd()` | A card per value, with the line that called it. `dd()` ends the run. |
| An Eloquent model, collection, or paginator | What the models hold: class and key, attributes, and loaded relations, with changed, new, and hidden ones marked. **Values \| Object** switches to the whole object ([Eloquent models](running-code.md#eloquent-models-values-or-object)). |
| An uncaught exception | An **error card**: the class, the message, **Go to line N**, the source around the line, its cause, and the stack trace. The editor marks the line. |
| `\Runlet\notice()`, `warning()`, `error()` | Your own cards, with the calling line. The run goes on and doesn't fail. |
| A mailable, view, or HTML response you return or dump | A [rendered preview](#previews) next to the value tree. |

The [Snippet API](snippet-api.md) has the details of each one: how results are read, the bounds on values, and the source excerpts in error cards.

Your project's driver can decide how its own types show, such as a `Money` object as `46.99 EUR`, with [casters](drivers.md#casters). A value a caster shows has a small wand mark after its class: click it to see the object as Runlet sees it.

File paths in errors and stack traces are links. A project file opens at its line in your editor (choose it in **Settings ▸ Editor**); vendor code opens in a read-only peek next to the output.

### Your Own Notices, Warnings, and Errors

Put a card in the output without stopping the run:

```php
\Runlet\notice('Imported 120 rows', ['skipped' => 3]);
\Runlet\warning('Cache is cold', ['store' => 'redis']);
\Runlet\error('3 orders have no customer');
```

Each card links to the line that called it, and shows its context as a value you can expand. An error card is marked **not fatal**: the run doesn't count as failed. The run's footer counts the warnings and errors. See [Notices, warnings, and errors](snippet-api.md#notices-warnings-and-errors).

### Copying and Exporting

| To | Use |
| --- | --- |
| Copy the whole output | **Copy Output** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd>), as the current view shows it |
| Copy it as Markdown, or save it to a file | The pane's share menu: **Copy Output as Markdown**, **Save Output As…** |
| Copy one value | Its card's copy button: **Copy as JSON**, **Copy as PHP**, or **Copy as Markdown** |
| Export a table | **Copy CSV** or **Export CSV…** above the table, or **Open in Window** for filters and sorting |
| Start over | **Clear Output** (<kbd>⌘</kbd><kbd>K</kbd>) clears the output and the sections |

## Queries

**Queries** lists every SQL statement the run sent, in order. Each row shows:

- the statement with its bindings filled in;
- its time (the slowest statement of the run is orange);
- the connection, and the database driver when it differs;
- **line N**, the snippet line that ran it, which moves the caret there.

The summary at the top reads like "14 queries · 12.30 ms · 2 repeated statements". Click a row's chevron for the whole statement, the statement as sent with its placeholders, and each binding with its type. **Filter** keeps the statements whose SQL or connection contains what you type.

### N+1 and Duplicate Hints

Runlet compares the statements of a run and flags two patterns:

| Hint | Means | Usually |
| --- | --- | --- |
| **3× identical** | The same statement, with the same bindings, ran 3 times. | Cache the result, or run it once. |
| **N+1? 6×** | A similar `SELECT` ran 6 times with different bindings: three times or more. | One query per row of an earlier result. Eager load the relation (`with()` in Eloquent) to fetch them in one query. |

The hints appear on the rows and as chips at the top of the section. Click a chip to list only those statements, and **Show All** to see everything again. **Group Similar** shows one row per statement shape instead, with how often it ran, its total time, and how many distinct statements it had.

```php
// N+1: one query for the orders, then one per order for its customer.
Order::latest()->take(10)->get()->map(fn ($order) => $order->customer->name);

// One query for the customers instead.
Order::with('customer')->latest()->take(10)->get()->map(fn ($order) => $order->customer->name);
```

### Copying and Explaining a Statement

- The copy button (or the row's context menu) has **Copy SQL**, **Copy SQL with Bindings**, and **Copy Bindings as JSON**.
- **Explain** opens a new PHP tab with the plan request for that statement. Nothing runs until you press Run. See [Explain a Captured Query](sql-explain.md).

What Runlet records depends on the framework: Laravel, Eloquent, Doctrine connections in Symfony, and WordPress's `$wpdb` work without any setup. The table is in [Installation](installation.md#supported-environments); a [project driver](drivers.md) can add plain PDO or Doctrine connections with one line.

> [!NOTE]
> Queries your application runs while it boots aren't recorded: Runlet starts listening once the application is up, right before your snippet runs.

## Mail

**Mail** lists every message the run sent, as a card:

- the status: **SENT**, **INTERCEPTED** (recorded, not sent), **QUEUED** (pushed to a queue that a worker sends later), or **FAILED**, with the mailer's error;
- the subject, From, To, Cc, Bcc, and Reply-To;
- the mailable, **Sent by** (who sent it, when that isn't your snippet), the mailer, and the attachments with their sizes;
- a [preview](#previews) of the message, with HTML, Text, and Source views.

Laravel's mail (and notifications sent by mail), Symfony Mailer, and WordPress's `wp_mail()` are recorded without any setup. Mail sent some other way, such as a raw SMTP client or a mail service's HTTP SDK, isn't recorded.

### Intercepting Mail

Turn on interception, and mail sent during a run is recorded but never delivered: try a password reset or an order confirmation without emailing anyone.

- **The default** is in **Settings ▸ General ▸ Run Inspector ▸ Intercept mail** (off). **Run ▸ Toggle Mail Interception** switches it.
- **Per target,** a local project, Docker profile, or SSH profile can override the default in its options: **Default**, **Intercept (record, don't send)**, or **Send**.

How it works depends on the framework:

| Framework | Intercepted |
| --- | --- |
| Laravel | Every message, after Laravel builds it completely (views, attachments), including notifications sent by mail. |
| Symfony Mailer | 6.3 and later. Older versions record the mail and send it. |
| WordPress | 5.7 and later, through `wp_mail()`. Not when a plugin replaces `wp_mail()` itself, as some SMTP and mail API plugins do. |
| Your own driver | When the driver supports it; see [Mail interception](drivers.md#mail-interception). |

> [!WARNING]
> Interception covers what is sent during the run. Mail pushed to an asynchronous queue is sent later by a queue worker, outside the run, so Runlet lists it as **QUEUED** and can't stop it. The same goes for mail sent by WP-Cron events and Action Scheduler jobs. When interception is on but a project's driver can't confirm it, the Mail section says that mail was delivered normally, and why.

### The Mail Chip

The header of every PHP tab's output says what runs on its target do with mail:

- **Intercepting Mail** (orange);
- **Sending Mail** (grey, or red on a production target);
- **Mail: inspector off**, dimmed, when the run inspector is off: runs send mail and record nothing.

Click the chip to see where the setting comes from and to change it for the target, from the next run. Switching a production target from intercepting to sending asks first. After a run that asked for interception, the chip also says whether the project's driver confirmed it.

## Previews

When a snippet returns or dumps something with an HTML rendering, the value card shows a **Preview** next to the tree:

- Laravel mailables, mail notifications (their `toMail()`), views, and `Htmlable` and `Renderable` objects;
- Symfony responses with HTML content;
- the messages in **Mail**, and HTML a driver records.

```php
return new App\Mail\OrderShipped(App\Models\Order::first());
```

Previews are locked down: no JavaScript, no navigation, and nothing loaded from the network. Links you click open in your browser. Emails often contain tracking pixels, so remote images load only when you tick **Load Remote Images** for that one preview.

Each preview has **HTML**, **Text** (for mail with a text body), and **Source** views, and its menu has **Copy HTML**, **Copy Text**, and **Open in Window**. A preview shows the first 2 MiB of HTML.

Rendering a preview runs your application's view code, so its queries appear in **Queries**. To skip previews, turn off **Settings ▸ General ▸ Run Inspector ▸ Preview returned mail, views, and HTML**. A [project driver](drivers.md#previews) can preview types of its own.

## Log

On Laravel, Lumen, and Laravel Zero, **Log** lists the messages the run logged through the framework's logger, with their level, channel, message, context, and the line that logged them. A driver or a snippet can add messages too.

**Show in Logs Window** opens the [Log Viewer](logs.md) with **Last Run** on: the lines the run added to the target's log files.

## HTTP

**HTTP** lists the requests a run made through Laravel's HTTP client (the `Http` facade) or WordPress's HTTP API (`wp_remote_get()` and friends), in the order they finished:

```php
use Illuminate\Support\Facades\Http;

Http::fake(['api.example.com/*' => Http::response(['id' => 1042], 201)]);

Http::withToken('example-api-token')
    ->post('https://api.example.com/v1/orders?signature=abc123', ['sku' => 'TSHIRT-M']);
```

Each row shows the method, the status (green for 2xx, orange for 4xx, red for 5xx and failed connections), the URL, the time from sending to the response, and the snippet line that sent it. Click the chevron for the request and response headers and, when you turn them on, the bodies.

![The HTTP section: a faked POST opened, with the Authorization and X-Api-Key headers redacted and the JSON bodies pretty-printed, then a faked 404, a request to a local server, and a failed connection](screenshots/run-inspector/http-light.webp#gh-light-mode-only)
![The HTTP section: a faked POST opened, with the Authorization and X-Api-Key headers redacted and the JSON bodies pretty-printed, then a faked 404, a request to a local server, and a failed connection](screenshots/run-inspector/http-dark.webp#gh-dark-mode-only)

- **FAKED** marks a response that never came from the network: `Http::fake()` answered it, or, in WordPress, a `pre_http_request` filter. Requests a fake doesn't match go out as usual, and aren't marked.
- **FAILED** means no response came, such as a refused connection. The row shows the error.
- **Filter** keeps the requests whose method, URL, or status contains what you type.

Copy a request's URL, its bodies, or a one-line summary from its copy button or context menu. **Copy Output as Markdown** lists the requests too.

### Credentials Are Redacted

Runlet replaces credentials with `[redacted]` before anything leaves PHP, so they never reach the app, the screen, or a copied summary:

| Where | Redacted |
| --- | --- |
| Headers | `Authorization` and `Proxy-Authorization` (the scheme stays: `Bearer [redacted]`), `Cookie` and `Set-Cookie` (the cookie names and attributes stay), API-key headers such as `X-Api-Key`, `X-Auth-Token`, and `X-CSRF-Token`, and any header whose name contains `token`, `secret`, `password`, `signature`, `api-key`, `auth`, `credential`, `session`, or `cookie` |
| The URL | The password in `user:password@`, and query parameters named like secrets: `token`, `key`, `api_key`, `secret`, `password`, `signature`, `sig`, `code`, `auth`, `session`, … |
| Bodies | JSON fields and form fields with those names, at any depth |
| Errors | The same secrets in URLs inside the error message |

### Request and Response Bodies

Bodies aren't recorded until you turn on **Settings ▸ General ▸ Run Inspector ▸ Include request and response bodies**: the row shows only their size. With it on, each body shows its first 8 KB, with JSON pretty-printed. Binary bodies and multipart uploads show only their size, and a streamed response is never read.

> [!WARNING]
> Bodies can hold personal data and secrets that Runlet can't recognise by name: a customer's address, a token in a field called `value`, a document. Redaction is a safety net, not a guarantee. Turn bodies on while you need them, and leave them off on production targets.

## Jobs

**Jobs** lists the jobs a run pushed to a queue and the jobs it ran. On the `sync` queue, which the sandbox uses, a dispatched job runs right away, inside the run:

```php
SendWelcomeEmail::dispatch($user->id);            // sync: runs now, PROCESSED or FAILED

SendWelcomeEmail::dispatch(2)
    ->onConnection('database')
    ->onQueue('emails')
    ->delay(now()->addMinutes(5));               // QUEUED: a worker runs it later
```

![The Jobs section: a job the sync queue ran in 14 ms, one that failed with its exception, and one queued on the database connection's emails queue, opened to show its class, queue, and ID](screenshots/run-inspector/jobs-light.webp#gh-light-mode-only)
![The Jobs section: a job the sync queue ran in 14 ms, one that failed with its exception, and one queued on the database connection's emails queue, opened to show its class, queue, and ID](screenshots/run-inspector/jobs-dark.webp#gh-dark-mode-only)

| Status | Means |
| --- | --- |
| **PROCESSED** | The job ran during the run and finished. The row shows how long it took. |
| **FAILED** | The job ran and threw, or the queue failed it. The row shows the exception. |
| **QUEUED** | The job went to a queue: a worker runs it later, outside the run. The row shows the connection, the queue, the delay, and the job's ID. |
| **RELEASED** | A worker released the job after an exception, to try it again. |
| **DIDN'T FINISH** | The run ended while the job was still running, for example with `dd()` or `exit`. |
| **NOT QUEUED** | Laravel started to queue the job, but the queue never confirmed it: pushing it probably failed. |

Queued mail, notifications, event listeners, broadcasts, and closures run inside one of Laravel's wrapper jobs. The row shows what the job runs, such as your mailable, with the wrapper next to it (**via SendQueuedMailable**). Queued mail is in **Mail** too, as **QUEUED** when a worker sends it later, and as sent when the sync queue sends it during the run.

Jobs run with `dispatchSync()` or `dispatch_sync()` don't go through a queue, so they aren't listed.

## Events

**Events** lists the events your application dispatched, with a short summary of each one's payload. It's off by default, because a busy run dispatches hundreds of events. Turn it on in **Settings ▸ General ▸ Run Inspector ▸ Record events**.

![The Events section with Record events on: Eloquent's saving, creating, created, and saved events for a new user, a cache miss and write, the snippet's OrderShipped event opened to show its order ID and carrier, and a cart.updated string event](screenshots/run-inspector/events-light.webp#gh-light-mode-only)
![The Events section with Record events on: Eloquent's saving, creating, created, and saved events for a new user, a cache miss and write, the snippet's OrderShipped event opened to show its order ID and carrier, and a cart.updated string event](screenshots/run-inspector/events-dark.webp#gh-dark-mode-only)

- **What's left out:** events other sections already show (queries, mail, logs, HTTP, and jobs), and the framework's own bookkeeping, such as `bootstrapped: …`, `eloquent.booted: …`, `eloquent.retrieved: …`, view `composing: …` events, routing, console, Redis commands, and log context.
- **Payloads** are summaries: three levels deep, 20 entries per level, and 512 bytes per string. They're read like a dump, so no getter or accessor of yours runs.
- **Filter** keeps the events whose name contains what you type.

Recording events never changes what your application does: Runlet's listener runs after your listeners and returns nothing, so it can't stop an event or answer `Event::until()`. An event a listener stops (by returning `false`) or that throws in a listener before Runlet's turn isn't listed.

## Sections of Your Own

A [project driver](drivers.md#custom-sections-logs-html) can add sections, such as **Cache** or **Payments**. A snippet can record values too:

```php
$inspector = \Runlet\Inspector::current();

$inspector->record('Debug', 'cart', $cart);
$inspector->log('info', 'Checked out', ['order' => $order->id]);
```

Each record links to the line that recorded it. Every method is listed in [The run inspector](snippet-api.md#the-run-inspector).

## Benchmarks and Profiles

`\Runlet\bench()` adds a **Benchmarks** section, and **Run ▸ Profile Run** adds a **Profile** section with a flame graph. See [Benchmarks & Profiling](benchmarks.md).

## Choosing What's Recorded

**Settings ▸ General ▸ Run Inspector** has a switch for each part of the inspector:

| Setting | Default | Records |
| --- | --- | --- |
| **Record queries, mail, and logs** | On | The whole inspector. Turned off, runs record nothing, and drivers add no sections. `\Runlet\notice()`, `warning()`, and `error()`, benchmarks, and profiles still show: your snippet asked for them. |
| **Record HTTP requests** | On | The **HTTP** section. |
| **Include request and response bodies** | Off | [Bodies](#request-and-response-bodies) in the **HTTP** section. |
| **Record jobs** | On | The **Jobs** section. |
| **Record events** | Off | The **Events** section. |

The switches apply to every target. **Intercept mail** keeps the inspector on for its runs, so these sections record then too.

## Limits

To keep the app fast, each run records at most:

- 2,000 statements, and 2,000 other records;
- 8 MiB of records in all, and 2 MiB per HTML or text body;
- values 6 levels deep, 100 entries per level, 16 KiB per string, and 512 KiB per value;
- 200 HTTP requests and 2 MiB of them, with 8 KB per body;
- 500 jobs;
- 500 events and 1 MiB of them.

A section that reached a limit says how many records it left out, at its end.

## For developers

| Piece | Where |
| --- | --- |
| The section bar, Queries, Mail, Log, and driver sections | `Runlet/Features/InspectorViews.swift` (`OutputSectionBar`, `QueriesSectionView`, `MailSectionView`, `RecordsSectionView`) |
| The duplicate and N+1 hints: statement fingerprints, groups, the threshold of 3 similar `SELECT`s | `QueryAnalysis` in `Packages/RunletKit/Sources/RunletCore/QueryAnalysis.swift` |
| The locked-down preview: content rules that block every load except `about:` and `data:` URLs (and remote images when allowed) | `Runlet/Features/HTMLPreview.swift` (`HTMLPreviewView`, `PreviewRules`) |
| The mail chip, Toggle Mail Interception, and the target's Mail option | `Runlet/App/AppModel+Inspector.swift`, `MailInterceptionChip` in `Runlet/Features/OutputPane.swift` |
| The output views, copying, and exporting | `Runlet/Features/OutputPane.swift`, `Runlet/Features/ValueTableGrid.swift` |
| The runner's side: the inspector, its hooks per framework, and its limits | `Resources/Runner/src/Inspector.php`; how drivers report to it: [Run inspector](drivers.md#run-inspector) |
| HTTP, Jobs, and Events: the views, the debug steps | `Runlet/Features/RunRecorderViews.swift` (`HTTPSectionView`, `JobsSectionView`, `EventsSectionView`), `Runlet/App/RecorderDebugSteps.swift` |
| HTTP, Jobs, and Events: the records, redaction, and listeners | `HTTPRecord`, `JobRecord`, and `EventRecord` in `Packages/RunletKit/Sources/RunletCore/RunRecorder.swift`; `Resources/Runner/src/Recorders.php` ([Run Inspector Hooks](driver-inspector.md#http-jobs-and-events)) |

History: HTTP, Jobs, and Events in [#5](https://github.com/filipac/runlet/issues/5), Explain for captured queries in [#4](https://github.com/filipac/runlet/issues/4), WordPress mail in [#192](https://github.com/filipac/runlet/issues/192), the mail chip in [#193](https://github.com/filipac/runlet/issues/193), `\Runlet\notice()`, `warning()`, and `error()` in [#196](https://github.com/filipac/runlet/issues/196), and Show in Logs Window in [#20](https://github.com/filipac/runlet/issues/20). This page took in the readme's "See everything your code touched" section in [#291](https://github.com/filipac/runlet/issues/291).
