# Snippet API

This page lists everything a snippet can use in Runlet: how it runs, what shows up in the output, magic comments, the `Runlet\` functions, the run inspector, snippet inputs, and the variables your framework hands you.

The same API works on every target (the Laravel sandbox, local projects, Docker containers, and SSH servers) and on PHP 7.4 and later. To boot an application Runlet doesn't detect, or to add inspector sections of your own, write a [project driver](drivers.md).

## How a Snippet Runs

- **Each run is a fresh PHP process.** The application boots, then your snippet runs. Variables don't carry over between runs. When you want them to, **Library ▸ Open REPL** opens the target's Tinker, PsySH, or `php -a` in a terminal.
- **`<?php` is optional.** Without it, Runlet adds it on the first line, so line numbers stay as you see them.
- **The last expression is the result,** as in Tinker. `User::count()` on the last line shows its value. An explicit `return` works too, and the final semicolon may be left out. A last statement that isn't an expression, such as `echo` or `foreach`, gives no result.
- **Run Selection** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>) runs only the selected code, and lines in the output point back at the editor's lines.
- **Strict types.** Turn on **Settings ▸ General ▸ Running ▸ Declare strict_types=1 for every run** to add `declare(strict_types=1);` on the first line. Projects and Docker profiles can override it, and code that declares `strict_types` itself is left alone.
- **Working directory.** The snippet runs in the project's folder: the container's or the server's for Docker and SSH targets. `getenv('RUNLET_RUN_ID')` is the run's id.

```php
use App\Models\User;

$users = User::where('active', true)->get();

$users->pluck('email')
```

The last line is the result: a collection of emails, with no `return` or semicolon needed.

[Running Code](running-code.md) covers Run, Stop, and the output pane.

## Output

| In the snippet | In the output |
| --- | --- |
| The last expression, or `return` | A **Result** card: an expandable tree, a table for rows and collections, and [string viewers](string-viewers.md) for JSON, long text, images, and HTML. |
| `echo`, `print`, `printf`, writes to `STDOUT` | Printed output, as written. Writes to `STDERR` are orange. **Raw** has exactly what PHP wrote, up to 8 MiB per run. |
| `dump($a, $b)`, `dd(...)` | A **dump** card per value, with the line that called it. `dd()` ends the run, which still counts as completed. They use your project's VarDumper, or Runlet's own `dump()` and `dd()` when there is none. |
| An uncaught exception or error | An **error card**: the class, the stage (`runtime`, `parse`, `bootstrap`, or `fatal`), the message, **Go to line N** (or the file and line), [the source where it failed](#source-excerpts), its cause, and the stack trace. The editor marks the line, and the run fails. |
| `exit()` or `die()` | The run ends. It fails when the exit code isn't 0. |
| `\Runlet\notice()`, `warning()`, `error()` | Notice, warning, and error cards with the calling line. The run goes on and doesn't fail ([below](#notices-warnings-and-errors)). |
| A returned or dumped mailable, mail notification, view, `Htmlable`, `Renderable`, or HTML Symfony response | An HTML **preview** next to the value tree, with JavaScript off, no navigation, and no remote loads unless you allow images for that preview. A project driver can add types; Settings can turn previews off. See [Previews](drivers.md#previews). |

Results and dumps are bounded: depth 8, 200 entries per level, 64 KiB per string, and 2 MiB per value. Runlet reads values without calling your code: no getters, `__toString()`, `__debugInfo()`, or `__get()`. The **Structured**, **Plain**, and **Raw** views show the same run; Plain and Raw, **Copy Output**, and **Save Output As…** always have everything.

### Source Excerpts

An error card shows the code where the error happened: about five lines around it, numbered and coloured like the editor, with the failing line marked. When **Go to line N** is your snippet's line but the error was thrown in a file, the card says **Thrown in** that file and shows its lines.

- **Stack frames.** Each frame with source has a ▸ that shows its lines. The first frame in a project file starts open (unless the card already shows it). The snippet's own frames, vendor code, and files outside the project stay closed until you open them.
- **Where the lines come from.** The snippet's lines are the code that ran: for Run Selection, the selection, numbered as in the editor. Files are read on your Mac: from the project folder for local projects and the sandbox, and from the profile's local folder for Docker and SSH targets. Those excerpts are marked **local copy**, because the file in the container or on the server may differ; the tooltip says where it is there.
- **Files that aren't on your Mac,** such as a compiled view that was cleared, a server path outside the profile's folder, or a profile without a local folder, show **Source not available here** with the path, and the tooltip says why. A file that got shorter since the run says so too.
- **Clicking a line.** A snippet line moves the caret there. A project file opens at that line in your external editor (**Settings ▸ Editor ▸ External Editor**). Vendor code, files outside the project, and any file when no editor is set open in the read-only peek of [Go to Definition](navigation.md). Nothing runs.
- **Bounds.** Runlet reads only the lines it needs, in the background, at most 8 MB into a file and 300 characters per line, once per run.

## Notices, Warnings, and Errors

Three functions put a card in the output, with the snippet line that called them, without ending the run:

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
| `\Runlet\notice(string $message, array $context = []): void` | A blue notice card. |
| `\Runlet\warning(string $message, array $context = []): void` | An orange warning card, like Runlet's own warnings. |
| `\Runlet\error(string\|\Throwable $message, array $context = []): void` | A red error card marked **not fatal**. With a `Throwable`, the card shows its class and message, where it was thrown (when that isn't the calling line) with [its source](#source-excerpts), its cause, and its stack trace. |

The run inspector has the same three as methods: `\Runlet\Inspector::current()->notice($message, $context)`, `->warning(…)`, and `->error(…)`. They behave exactly like the functions.

- **The line.** The card links to the snippet line that called it. When no snippet line is on the stack, such as in a driver's `bootstrap()`, it links to the first project file outside `vendor/`, which opens in your editor.
- **Context.** `$context` shows under the message as a collapsed value, read without calling your code and bounded: depth 6, 100 entries per level, 16 KiB per string, and 512 KiB per value.
- **Never a failure.** An error card doesn't make the run fail: Run History, notifications for long runs, and AI clients don't count it as an error, and the editor doesn't mark the line. The run's footer counts warnings and errors ("2 warnings, 1 error"); notices aren't counted.
- **They never throw.** `error()` takes anything: a string, a `Throwable`, or any other value as short text (`42`, `array(3)`, a class name, or a `Stringable`'s text). `notice()` and `warning()` are typed, so PHP checks their arguments as for any function.
- **Always shown.** The cards show whether the run inspector is on or off, and they aren't inspector records.
- **Bounds.** A message keeps its first 16 KB, and the card notes the rest. A run shows at most 200 of these cards and 8 MB of them; a notice at the end says how many were left out.
- **Secrets.** A saved database connection's password is replaced by `•••` in the message, the context, and a `Throwable`'s details.
- **Plain text.** **Copy Output** and **Plain** read `⚠︎ Warning (line 3): Cache is cold`, followed by `Caused by …` and `Context: …` lines when there are any. Markdown export has the same.
- **AI clients** get each card as a line, such as `Warning (line 3): Cache is cold`, and as a structured message, not as an error. See [AI clients](mcp.md).

> [!TIP]
> The functions return nothing, so as the last line of a snippet they make the result `null`. Put the value you want to see last.

`trigger_error()` keeps PHP's behaviour, or your framework's: Laravel turns `E_USER_WARNING` and `E_USER_NOTICE` into exceptions, for example. Runlet doesn't turn it into cards; use `\Runlet\warning()` instead.

## Magic Comments

Magic comments show values in the editor while the code runs:

| Comment | Shows |
| --- | --- |
| `//?` at the end of a line | The line's value. `✓` on a line without a value, when it's reached. |
| `/*?*/` after an expression | That expression's value. |
| `/*?->count()*/` | A projection of the value before it; the code still gets the value itself. |
| `/*?.*/` | Milliseconds since the previous `/*?.*/`, or since the snippet started. |

[Magic Comments](magic-comments.md) has every form, loops, and the places Runlet skips.

## Runlet Functions

The runner defines these functions in the `Runlet` namespace on every target:

| Function | What it does |
| --- | --- |
| `\Runlet\notice()`, `\Runlet\warning()`, `\Runlet\error()` | Cards in the output ([above](#notices-warnings-and-errors)). |
| `\Runlet\bench($callables, int $iterations = 1000, ?string $label = null, ?float $seconds = null): array` | Measures a callable, or up to 20 labelled callables side by side, and shows a benchmark card: mean, median, p95, min, max, operations per second, memory, and a histogram. Returns the numbers in milliseconds. Shown even with the inspector off. See [Benchmarks](drivers.md#benchmarks). |
| `\Runlet\explainPlan($rows, $connection = null, ?string $connectionName = null)` | Shows EXPLAIN rows as Runlet's plan card: a tree with full scans highlighted, and the database's own output under **Raw**. Rows it can't read as a plan come back as they are. See [SQL Explain](sql-explain.md). |

```php
use Illuminate\Support\Str;

Runlet\bench(fn () => Str::slug('Ada Lovelace'), 5000, 'Str::slug()');
```

The functions exist only when Runlet runs the code. Code that should also run elsewhere can check first: `function_exists('Runlet\bench')`.

## The Run Inspector

`\Runlet\Inspector::current()` returns the run's inspector, or `null` outside a snippet run (for example, while Runlet lists a project's commands). What a snippet records shows in the inspector's sections next to the output, with the snippet line:

```php
$inspector = \Runlet\Inspector::current();

$inspector->record('Debug', 'cart', $cart);
$inspector->log('info', 'Checked out', ['order' => $order->id]);
```

| Method | Purpose |
| --- | --- |
| `notice(string $message, array $context = [])`, `warning(…)`, `error(string\|\Throwable $message, array $context = [])` | Cards in the output, like the functions above. Shown with the inspector off too. |
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

No method throws. With the inspector off (**Settings ▸ General ▸ Run Inspector ▸ Record queries, mail, and logs**), the recording methods do nothing and `watchPdo()` returns `false`; `notice()`, `warning()`, `error()`, and `bench()` still show. Limits and the hooks drivers use are in [Run inspector](drivers.md#run-inspector).

## Snippet Inputs

A snippet can declare inputs in its docblock, and Runlet asks for their values when you open it:

```php
/**
 * @label Refund order
 * @input int $orderId "Order ID"
 * @input string $reason "Reason" = "duplicate" {duplicate, fraudulent}
 */
```

Opening it puts `$orderId = 1042;` and the other values at the top of the code, and never runs it. [Snippet Inputs](snippet-inputs.md) has the types, defaults, and choices.

## Driver Variables

The driver that boots your project puts variables in the snippet's scope:

| Project | Variables |
| --- | --- |
| Laravel, Lumen, Laravel Zero | `$app` |
| WordPress | `$wpdb` |
| Symfony | `$kernel`, `$container` |
| Composer projects, plain PHP | none |
| A project driver | what its `variables()` returns |

A snippet can reassign them without affecting the driver, and completion knows their types. See [Variables and reporting](drivers.md#variables-and-reporting).

## Completion

`\Runlet\` completes in the editor, with hover and signature help, in every PHP tab. That includes Docker and SSH targets without a local checkout.

## For developers

The snippet API reference is [#196](https://github.com/filipac/runlet/issues/196), which added `\Runlet\notice()`, `warning()`, and `error()`; source excerpts are [#8](https://github.com/filipac/runlet/issues/8). Saved connections' passwords, which the cards scrub, are [#138](https://github.com/filipac/runlet/issues/138).

**Runner protocol.** Each card is a `notice` event with `level` (`notice`, `warning`, or `error`), `user: true`, the caller's `inSnippet`/`snippetLine` or `file`/`line`, and, when present, `context` (a value node), `omittedBytes`, and `exception` (`className`, where it was thrown, `trace`, `previous`). Runlet's own notices stay a plain `{message}`, and app builds from before #196 read only `message`, so they show a card's text as a notice.

**MCP.** `run_php` and `get_last_output` include each card as a line and list them in `structuredContent.messages` (`level`, `message`, `line`, `file`, `fileLine`, `class`, `context`), not in `errors`.

**Completion.** Runlet gives PHPantom the declarations of the `Runlet\` functions and `\Runlet\Inspector`'s public methods as an in-memory document, never written to disk. `RunletAPIStubTests` checks that they match the runner's.

**Tests.**

- `SnippetMessageRunnerTests` (needs a local `php`): the three functions and the inspector's methods with the inspector on and off, the calling line and a project file outside the snippet, context, a `Throwable`'s class, trace, and cause, the 200-card bound and 16 KB clip, arguments that never throw, scrubbed secrets, Runlet's own notices staying plain, and PHP 7.4. `SnippetMessageRemoteTests` runs the same snippet in the `runlet-fixtures` Laravel and PHP 7.4 containers and over the SSH fixture.
- `SnippetMessageTests`: decoding plain and levelled `notice` events, card text, the footer's counts, MCP results, and that a run with error cards is completed for history and notifications.
- `SourceExcerptTests` (excerpt bounds, first and last lines, CRLF, long lines, Latin-1, binary and missing files, the selection's line numbers, project/vendor/outside files, local copies for Docker and SSH, the sandbox's mounted files, and reading once per run) and `SourceExcerptExecutionTests` (needs a local `php`: an exception from a project class through vendor code gives a card, project, vendor, and snippet frames whose excerpts resolve); `FramePeekTests` for the peek. Screenshots: `scripts/source-excerpt-screenshots.py`.
- `RunletAPIStubTests`: the stub's signatures match the built runner's by reflection, and PHPantom completes `\Runlet\` and `Inspector::current()->` and hovers `\Runlet\warning`.
