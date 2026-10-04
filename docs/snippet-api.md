# Snippet API

Everything a snippet can use in Runlet, in one place: how a snippet runs, what shows up in the
output, magic comments, the `Runlet\` functions, the run inspector, snippet inputs, and the
variables a driver hands you. The runner defines the same API on every target (the Laravel
sandbox, local projects, Docker containers, and SSH servers) and on PHP 7.4 and later.

Tracked in [#196](https://github.com/filipac/runlet/issues/196). To boot an application Runlet
doesn't detect, or to add inspector sections, see [project drivers](drivers.md).

## How a snippet runs

- **Each run is a fresh PHP process.** The driver boots the application, then the snippet runs.
  Variables don't carry over between runs (Open REPL in the Commands pane keeps state).
- **`<?php` is optional.** Without it, Runlet adds it on the first line, so line numbers stay as
  you see them.
- **The last expression is the result**, as in Tinker: `User::count()` on the last line shows
  its value. An explicit `return` works too, and the final semicolon may be left out. A last
  statement that isn't an expression (`echo`, `foreach`, …) gives no result.
- **Run Selection** (⇧⌘R) runs the selected code; lines in the output map back to the editor.
- **`strict_types`:** Settings ▸ General ▸ Running ▸ *Declare strict_types=1 for every run*
  (projects and Docker profiles can override it) adds `declare(strict_types=1);` on the first
  line, unless the code declares strict_types itself.
- The snippet runs in the project's working directory (the container's or the server's for
  Docker and SSH targets), and `getenv('RUNLET_RUN_ID')` is the run's id.

## Output

| In the snippet | In the output |
| --- | --- |
| The last expression, or `return` | A **Result** card: an expandable tree, a table for rows and collections, and for strings the [string viewers](string-viewers.md) (JSON, long text, images, HTML). |
| `echo`, `print`, `printf`, output to `STDOUT` | Printed output, as written. Output to `STDERR` is shown in orange. Raw has exactly what PHP wrote (up to 8 MiB per run). |
| `dump($a, $b)`, `dd(...)` | A **dump** card per value, with the line that called it. `dd()` ends the run; it still counts as completed. They go through your project's VarDumper, or Runlet's own `dump()`/`dd()` when there is none. |
| An uncaught exception or error | An **error card**: the class, the stage (`runtime`, `parse`, `bootstrap`, `fatal`), the message, *Go to line N* (or the file and line), [the source where it failed](#source-excerpts), its cause, and the stack trace. The editor marks the line. The run fails. |
| `exit()` / `die()` | The run ends; it fails when the exit code isn't 0. |
| `\Runlet\notice()`, `warning()`, `error()` | Notice, warning, and error cards with the calling line; the run goes on and doesn't fail ([below](#notices-warnings-and-errors)). |
| A returned or dumped mailable, mail notification, view, `Htmlable` or `Renderable`, or HTML Symfony response | An HTML **preview** next to the value tree, with JavaScript off, no remote loads (images can be allowed per preview), and no navigation. A project driver can add types with `preview()`; Settings can turn previews off. See [Previews](drivers.md#previews). |

Results and dumps are bounded: depth 8, 200 entries per level, 64 KiB per string, 2 MiB per
value. Values are read without calling your code (no getters, `__toString()`, `__debugInfo()`,
or `__get()`). The output pane's Structured, Plain, and Raw views show the same run; Plain and
Raw, Copy Output, and Save Output always have everything.

### Source excerpts

Error cards show the code where the error happened ([#8](https://github.com/filipac/runlet/issues/8)):
about five lines around the line, numbered and colored like the editor, with the failing line
marked. When *Go to line N* is your snippet's line and the error was thrown in a file, the card
says *Thrown in* that file and shows its lines.

- **Stack frames.** Each frame with source has a ▸ that shows its lines. The first frame in a
  project file is open at first (unless the card already shows it); the snippet's own frames,
  vendor code, and files outside the project stay closed until you open them.
- **Where the lines come from.** The snippet's lines are the code that ran (the selection's,
  numbered as in the editor, for Run Selection). Files are read on this Mac: the project folder
  for local projects and the sandbox, and the profile's local folder for Docker and SSH targets
  (the same mapping as file links). Those excerpts are marked **local copy**: the file in the
  container or on the server may differ, and the tooltip says where it is there.
- **Files that aren't here.** A file that doesn't exist on this Mac (a compiled view that was
  cleared, a server path outside the profile's directory, a profile without a local folder) shows
  *Source not available here* with its path; the tooltip says why. A file that changed since the
  run so it is shorter says so too.
- **Clicking a line.** A snippet line moves the caret there. A project file opens in your external
  editor at that line. Vendor code, files outside the project, and any file when no editor is set
  open in the read-only peek from [Go to Definition](navigation.md). Nothing runs.
- **Bounds.** Only the needed lines are read, in the background, at most 8 MB into a file and 300
  characters per line, once per run (a new run reads again). Plain and Raw output, Copy Output,
  and MCP results are unchanged.

## Notices, warnings, and errors

Three functions put Runlet's own kind of card in the output, with the snippet line that called
them:

```php
\Runlet\notice('Imported 120 rows', ['skipped' => 3]);
\Runlet\warning('Cache is cold', ['store' => 'redis']);

try {
    $client->sync();
} catch (\Throwable $e) {
    \Runlet\error($e, ['client' => $client->id]);
}

\Runlet\error('3 orders have no customer');
```

| Function | Card |
| --- | --- |
| `\Runlet\notice(string $message, array $context = []): void` | A blue notice card, with Runlet's info symbol. |
| `\Runlet\warning(string $message, array $context = []): void` | An orange warning card, like Runlet's own warnings. |
| `\Runlet\error(string\|\Throwable $message, array $context = []): void` | A red error card marked *not fatal*. The run goes on. With a `Throwable`, the card shows its class and message, where it was thrown (when that isn't the calling line) with [its source](#source-excerpts), its cause, and its stack trace, like an uncaught error's card. |

The same three are methods on the run inspector, for discoverability:
`\Runlet\Inspector::current()->notice($message, $context)`, `->warning(…)`, and `->error(…)`.
They behave exactly like the functions.

- **The line.** The card links to the snippet line that called it, or, when no snippet line is
  on the stack (a driver's `bootstrap()`, for example), to the first project file outside
  `vendor/`, which opens in your editor. Run Selection maps the line back to the editor.
- **`$context`** is shown under the message as a collapsed value you can expand, read without
  calling your code and bounded like the run inspector's values (depth 6, 100 entries per
  level, 16 KiB per string, 512 KiB per value).
- **Output, not records.** They show whether the run inspector is on or off, and they don't
  appear in an inspector section.
- **Never a failure.** An error card is not an error: the run's status, Run History,
  notifications for long runs, and MCP results don't count it as one. The run's footer counts
  the warnings and errors ("2 warnings, 1 error"); notices aren't counted. The editor doesn't
  mark the line.
- **They never throw.** `error()` takes anything: a string or a `Throwable`, and other values as
  short text (`42`, `array(3)`, a class name, or a `Stringable`'s `__toString()`, whose own
  exceptions are caught). `notice()` and `warning()` are typed `string $message, array
  $context`, so PHP checks those arguments as for any function.
- **Bounds.** A message keeps its first 16 KB (the card notes the rest). A run shows at most
  200 of these cards and 8 MB of them in all; one notice at the end says how many more were
  left out.
- **Secrets.** A saved connection's password ([#138](https://github.com/filipac/runlet/issues/138))
  is replaced by `•••` in the message, the context, and a `Throwable`'s details, as in every
  notice and error.
- **Copy Output and Plain** read `⚠︎ Warning (line 3): Cache is cold`, followed by
  `Caused by …` and `Context: …` lines when there are any; Markdown export has the same.
- **MCP.** `run_php` and `get_last_output` include each card as a line, such as
  `Warning (line 3): Cache is cold`, and list them in `structuredContent.messages` (`level`,
  `message`, `line`, `file`, `fileLine`, `class`, `context`), not in `errors`. See
  [mcp.md](mcp.md).
- They return nothing, so as the last line of a snippet the result is `null`; put the value you
  want to see last.

`trigger_error()` keeps PHP's behaviour, or your framework's (Laravel turns `E_USER_WARNING` and
`E_USER_NOTICE` into exceptions, for example): Runlet doesn't turn it into cards. Use
`\Runlet\warning()` instead.

**Runner protocol.** Each card is a `notice` event with `level` (`notice`, `warning`, or
`error`), `user: true`, the caller's `inSnippet`/`snippetLine` or `file`/`line`, and, when
present, `context` (a value node), `omittedBytes`, and `exception` (`className`, where it was
thrown, `trace`, `previous`). Runlet's own notices stay a plain `{message}`, and app builds from
before #196 read only `message`, so they show a card's text as a notice.

## Magic comments

Magic comments show values in the editor while the code runs, without `dump()`:

| Comment | Shows |
| --- | --- |
| `//?` at the end of a line | The line's value: an expression, an assignment's value, a `return`, or an `echo`. `✓` on a line without a value, when it's reached. |
| `/*?*/` after an expression | That expression's value. |
| `/*?->count()*/` | A projection of the value before it; the code still gets the value itself. |
| `/*?.*/` | Milliseconds since the previous `/*?.*/`, or since the snippet started. |

Adding them never changes what the code does. Settings ▸ General ▸ Magic Comments turns them
off. Every form, the bounds, and what can't be shown:
[compatibility.md](compatibility.md#magic-comments-10).

## Runlet functions

The runner defines these in the `Runlet` namespace on every target:

| Function | What it does |
| --- | --- |
| `\Runlet\notice()`, `\Runlet\warning()`, `\Runlet\error()` | Cards in the output ([above](#notices-warnings-and-errors)). |
| `\Runlet\bench($callables, int $iterations = 1000, ?string $label = null, ?float $seconds = null): array` | Measures a callable, or up to 20 labeled callables side by side, and shows a benchmark card (mean, median, p95, min, max, operations per second, memory, and a histogram). Returns the numbers in milliseconds. Shown even with the inspector off. See [Benchmarks](drivers.md#benchmarks). |
| `\Runlet\explainPlan($rows, $connection = null, ?string $connectionName = null)` | Shows EXPLAIN rows as Runlet's plan card: a tree with full scans highlighted, and the database's own output under Raw. Rows it can't read as a plan come back as they are. See [SQL Explain](sql-explain.md). |

Code that should also run outside Runlet can check first:
`function_exists('Runlet\bench')`.

## The run inspector

`\Runlet\Inspector::current()` returns the run's inspector (`null` outside a snippet run, such
as while Runlet lists commands). What a snippet records shows in the inspector's sections next
to the output, with the snippet line:

```php
$inspector = \Runlet\Inspector::current();
$inspector->record('Debug', 'cart', $cart);
$inspector->log('info', 'Checked out', ['order' => $order->id]);
```

| Method | Purpose |
| --- | --- |
| `notice(string $message, array $context = [])`, `warning(…)`, `error(string\|\Throwable $message, array $context = [])` | Cards in the output, like the functions above; shown with the inspector off too. |
| `record(string $section, string $title, $value)` | Any value in a section of your own, shown like a dump (bounded, no methods called). |
| `log(string $level, string $message, array $context = [], ?string $channel = null)` | One message in **Log**. |
| `html(string $title, string $html, string $section = 'HTML')` | Rendered HTML, previewed in a locked-down web view. |
| `query(string $sql, array $bindings = [], ?float $ms = null, ?string $connection = null, array $details = [])` | One statement in **Queries**. |
| `mail($message, array $details = [])` | One message in **Mail**: a Symfony Mime `Email`, a SwiftMailer message, or an array. |
| `watchPdo(\PDO $pdo, string $connection = 'pdo'): bool` | Records a PDO connection's prepared statements. |
| `section(string $section)` | Shows a section even when nothing is recorded in it. |
| `isEnabled(): bool` | Whether the inspector records this run. |
| `shouldInterceptMail(): bool`, `interceptingMail()`, `cannotInterceptMail(string $reason)` | [Mail interception](drivers.md#mail-interception), for drivers. |
| `once(string $key): bool`, `atFinish(callable $callback)`, `location(): array` | Helpers for hooks: attach once, run something when the run finishes, and where the running code came from. |
| `QUERIES`, `MAIL`, `LOG`, `HTML` | The built-in sections' names. |

No method throws. With the inspector off (Settings ▸ General ▸ Run Inspector ▸ *Record queries,
mail, and logs*), the recording
methods do nothing and `watchPdo()` returns `false`; `notice()`, `warning()`, `error()`, and
`bench()` still show. Limits and the hooks drivers use: [Run inspector](drivers.md#run-inspector).

## Snippet inputs

A snippet can declare inputs in its docblock, and Runlet asks for their values when you open it:

```php
/**
 * @label Refund order
 * @input int $orderId "Order ID"
 * @input string $reason "Reason" = "duplicate" {duplicate, fraudulent}
 */
```

Opening puts `$orderId = 1042;` and the other values at the top of the code, and never runs it.
Types, defaults, choices, and literals: [snippet-inputs.md](snippet-inputs.md).

## Driver variables

The driver that boots the project imports variables into the snippet's scope:

| Project | Variables |
| --- | --- |
| Laravel, Lumen, Laravel Zero | `$app` |
| WordPress | `$wpdb` |
| Symfony | `$kernel`, `$container` |
| Composer projects, plain PHP | none |
| A project driver | what its `variables()` returns |

A snippet can reassign them without affecting the driver. Editor completion knows their types.
See [Variables and reporting](drivers.md#variables-and-reporting).

## Editor completion

`\Runlet\` completes in the editor, with hover and signature help, in every PHP tab, including
Docker and SSH targets without a local checkout: Runlet gives PHPantom the declarations of the
`Runlet\` functions and `\Runlet\Inspector`'s public methods as an in-memory document (never
written to disk). `RunletAPIStubTests` checks that they match the runner's.

## Project drivers

A project driver in `.runlet/` boots an application Runlet doesn't detect, hands snippets their
variables, adds project and host commands, inspector sections, and previews. See
[drivers.md](drivers.md).

## Validation

- `SnippetMessageRunnerTests` (needs a local `php`): the three functions and the inspector's
  methods with the inspector on and off, the calling line and a project file outside the
  snippet, context, a `Throwable`'s class, trace, and cause, the 200-card bound and 16 KB clip,
  arguments that never throw, scrubbed secrets, Runlet's own notices staying plain, and PHP 7.4.
  `SnippetMessageRemoteTests` runs the same snippet in the `runlet-fixtures` Laravel and PHP 7.4
  containers and over the SSH fixture.
- `SnippetMessageTests`: decoding plain and leveled `notice` events, card text, the footer's
  counts, MCP results, and that a run with error cards is completed for history and
  notifications.
- `SourceExcerptTests` (excerpt bounds, first and last lines, CRLF, long lines, Latin-1, binary
  and missing files, the selection's line numbers, project/vendor/outside files, local copies for
  Docker and SSH, the sandbox's mounted files, and reading once per run) and
  `SourceExcerptExecutionTests` (needs a local `php`: an exception from a project class through
  vendor code gives a card, project, vendor, and snippet frames whose excerpts resolve);
  `FramePeekTests` for the peek. Screenshots: `scripts/source-excerpt-screenshots.py`.
- `RunletAPIStubTests`: the stub's signatures match the built runner's by reflection, and
  PHPantom completes `\Runlet\` and `Inspector::current()->` and hovers `\Runlet\warning`.
