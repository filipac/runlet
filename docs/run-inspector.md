# Run Inspector

Running PHP is half of it. Every run shows what happened, in the output pane next to your code: what the snippet printed and returned, its errors, the SQL it sent, the mail it sent, the logs it wrote, and anything your project's driver records.

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

Above the output, a bar lists **Output** and the run's sections, with their counts: **Queries**, **Mail**, and **Log** for what the project's framework records, then **HTML**, **Benchmarks**, **Profile**, and the sections a driver adds, once the run records something in them. Click one to show it in place of the output.

- An orange triangle on **Queries** means the run repeated a statement: a possible N+1 or duplicate query.
- An envelope on **Mail** means messages were intercepted, not sent.
- **Run ▸ Show Queries** and **Run ▸ Show Mail** (also in the command palette) open those sections. **Settings ▸ Shortcuts** can give them shortcuts.

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
| An uncaught exception | An **error card**: the class, the message, **Go to line N**, the source around the line, its cause, and the stack trace. The editor marks the line. |
| `\Runlet\notice()`, `warning()`, `error()` | Your own cards, with the calling line. The run goes on and doesn't fail. |
| A mailable, view, or HTML response you return or dump | A [rendered preview](#previews) next to the value tree. |

The [Snippet API](snippet-api.md) has the details of each one: how results are read, the bounds on values, and the source excerpts in error cards.

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

## Sections of Your Own

A [project driver](drivers.md#custom-sections-logs-html) can add sections, such as **Cache**, **HTTP calls**, or **Events**. A snippet can record values too:

```php
$inspector = \Runlet\Inspector::current();

$inspector->record('Debug', 'cart', $cart);
$inspector->log('info', 'Checked out', ['order' => $order->id]);
```

Each record links to the line that recorded it. Every method is listed in [The run inspector](snippet-api.md#the-run-inspector).

## Benchmarks and Profiles

`\Runlet\bench()` adds a **Benchmarks** section, and **Run ▸ Profile Run** adds a **Profile** section with a flame graph. See [Benchmarks & Profiling](benchmarks.md).

## Turning the Inspector Off

**Settings ▸ General ▸ Run Inspector ▸ Record queries, mail, and logs** is on by default. Turned off, runs record no queries, mail, or logs, and drivers add no sections. `\Runlet\notice()`, `warning()`, and `error()`, benchmarks, and profiles still show: your snippet asked for them.

## Limits

To keep the app fast, each run records at most:

- 2,000 statements, and 2,000 other records;
- 8 MiB of records in all, and 2 MiB per HTML or text body;
- values 6 levels deep, 100 entries per level, 16 KiB per string, and 512 KiB per value.

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

History: Explain for captured queries in [#4](https://github.com/filipac/runlet/issues/4), WordPress mail in [#192](https://github.com/filipac/runlet/issues/192), the mail chip in [#193](https://github.com/filipac/runlet/issues/193), `\Runlet\notice()`, `warning()`, and `error()` in [#196](https://github.com/filipac/runlet/issues/196), and Show in Logs Window in [#20](https://github.com/filipac/runlet/issues/20). This page took in the readme's "See everything your code touched" section in [#291](https://github.com/filipac/runlet/issues/291).
