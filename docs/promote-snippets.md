# Promote a snippet

Implemented in [#39](https://github.com/filipac/runlet/issues/39) (N36).

Scratch code that works often belongs in the project. **File ▸ Save as Artisan Command…** and
**File ▸ Save as Test…** turn the current tab's code into an Artisan command class or a Pest or
PHPUnit test in the tab's project, for you to review and commit. With a selection, only the
selection is used (the tab's `use` imports come along). Both commands are also in the Command
Palette (⇧⌘P) and in the Snippets panel's context menu for personal and project snippets.

Runlet only writes the file, and only where you choose in a save panel. It runs nothing: no
Artisan, no tests, no PHP. Opening, importing, or restoring code still never runs it, and
production confirmations are unchanged.

## Where the file goes

The save panel opens in the tab's project folder: in `app/Console/Commands` for a command
(`app/Commands` on Laravel Zero) and in `tests/Feature` for a test, or the nearest folder that
exists (New Folder creates the rest). The file name is filled in from the tab's title or the
snippet's label: `RefundOrder.php`, `RefundOrderTest.php`. The panel asks before it replaces a
file, and refuses names that can't work, keeping the panel open:

- not a PHP class name (letters, digits, and underscores, starting with a letter; not a reserved
  word);
- a test file whose name doesn't end in `Test.php` (Pest and PHPUnit only run those);
- a name the snippet already imports (`use App\Models\Order;` and `Order.php`).

The class name is the file name, and the namespace follows the folder through the project's
PSR-4 autoload map in `composer.json` (`app/Console/Commands` is `App\Console\Commands`,
`tests/Feature/Orders` is `Tests\Feature\Orders`), so the class autoloads where you saved it.

After saving, a sheet shows where the file went and any TODOs in it, and offers **Open in
<editor>** (Settings ▸ Editor) and **Reveal in Finder**.

## When they are available

| Target | Save as Artisan Command… | Save as Test… |
| --- | --- | --- |
| Local project | Laravel, Lumen, or Laravel Zero | Yes |
| Docker profile with a local source folder | Laravel family | Yes |
| SSH profile with a local folder (its checkout on this Mac) | Laravel family | Yes |
| The sandbox, or a profile without a local folder | No | No |
| SQL tabs | No | No |

A disabled command says why in the Command Palette and in its menu item's tooltip. The framework
comes from the target's last run or file detection; a project not detected yet counts as Laravel
when it has an `artisan` file.

## What the generated code looks like

Starting from this parameterised snippet ([#14](https://github.com/filipac/runlet/issues/14)):

```php
<?php

/**
 * Refund an order and tell the customer.
 *
 * @input int $orderId "Order ID"
 * @input string $reason "Reason" = "duplicate" {duplicate, fraudulent, requested_by_customer}
 * @input bool $notify "Email the customer" = true
 */

use App\Models\Order;
use App\Notifications\OrderRefunded;

$order = Order::findOrFail($orderId); //?
$order->refund($reason);

if ($notify) {
    $order->customer->notify(new OrderRefunded($order));
}

$order->fresh()->status
```

**Save as Artisan Command…** writes `app/Console/Commands/RefundOrder.php`, in the style of
`php artisan make:command`:

```php
class RefundOrder extends Command
{
    protected $signature = 'app:refund-order
                            {orderId : Order ID}
                            {--reason= : Reason (one of duplicate, fraudulent, requested_by_customer; default: duplicate)}
                            {--no-notify : Turn off: Email the customer}';

    protected $description = 'Refund order';

    public function handle()
    {
        /**
         * Refund an order and tell the customer.
         */

        $orderId = (int) $this->argument('orderId');
        $reason = $this->option('reason') ?? 'duplicate';
        $notify = ! $this->option('no-notify');

        $order = Order::findOrFail($orderId);
        $order->refund($reason);

        if ($notify) {
            $order->customer->notify(new OrderRefunded($order));
        }

        dump($order->fresh()->status);
    }
}
```

(The file also has `<?php`, the namespace, the imports, and the docblocks of Laravel's stub.)

**Save as Test…** writes a Pest test when the project uses Pest (`pestphp/pest` in
`composer.json`, `vendor/pestphp/pest`, or `tests/Pest.php`), otherwise a PHPUnit class that
extends the project's `Tests\TestCase` (or `PHPUnit\Framework\TestCase` when there is none):

```php
<?php

use App\Models\Order;
use App\Notifications\OrderRefunded;

test('Refund order', function () {
    // TODO: Choose a test value for $orderId (Order ID): its input has no default.

    /**
     * Refund an order and tell the customer.
     */

    $orderId = 0;
    $reason = 'duplicate';
    $notify = true;

    $order = Order::findOrFail($orderId);
    // …
    $result = $order->fresh()->status;

    // TODO: Assert the snippet's result, for example: expect($result)->toBe(...);
});
```

The rules:

- **The opening tag and imports.** `<?php` goes; `use` lines move to the file's imports, sorted,
  with the base class's (`Illuminate\Console\Command`, `Tests\TestCase`). When an import already
  takes the base class's name, the class extends it by its full name instead.
- **Declarations.** Named functions, classes, interfaces, traits, enums, and `const` at the top
  level move before the class (or the `test()` call): a snippet declares them before its code
  runs, and inside a method they would only exist once reached (`const` not at all). Closures and
  declarations inside `if` blocks stay where they are.
- **`declare(strict_types=1)`** is kept when the snippet declares it, and added when the target
  runs with strict types (Settings, or the project's override).
- **`namespace`.** A `namespace` statement or block is removed, with a TODO: the file has its own.
- **Magic comments** (`//?`, `/*?*/`, `/*?->…*/`, `/*?.*/`) are removed: they mean something only
  in Runlet's editor. Other comments stay.
- **The result.** The value Runlet would show as the result (the last expression statement, or a
  final `return`) is passed to `dump()` in a command. In a test it is assigned to `$result`, with
  a TODO to assert it, so the test doesn't fail or pass by accident: until you add assertions,
  Pest and PHPUnit report it as risky. When the last statement is an assignment (`$total = …;`)
  its variable is used instead, and a final `dump()` or `dd()` is left as it is.
- **Inputs.** `@input` lines leave the docblock. In a command, an input without a default is a
  required argument; one with a default or choices is an option read with its default (choices
  are listed in its description, not enforced); a `bool` is a flag, `--no-<name>` when it defaults
  to true. `int` and `float` values are cast. Option names are kebab-case and avoid the console's
  own (`--env`, `--verbose`, …). In a test, each input gets its default (`false` for a `bool`), or
  a typed empty value with a TODO, and a placeholder assignment in the snippet keeps its value.
  Declarations Runlet can't read are listed as TODOs.
- **Indentation.** The code is re-indented into the method or closure. Lines that start inside a
  string, heredoc, nowdoc, or inline HTML (and a `<?php` that reopens PHP after inline HTML) keep
  their exact text, so no string changes; flexible heredocs stay valid because their closing
  marker keeps its indentation.
- **Runlet's helpers** such as `Runlet\bench()` exist only when Runlet runs code; using one adds a
  TODO.

## Validation

- `SnippetPromotionTests` (23 tests): whole commands, Pest and PHPUnit tests, results,
  assignments and `return`, imports and groups, selections with the tab's imports, namespaces,
  declarations, magic comments, heredocs and multi-line strings, inline HTML, inputs as arguments
  and options, escaping of titles and labels, names, PSR-4 namespaces, and Pest detection.
- `SnippetPromotionPHPTests` (5 tests, with a local PHP; skipped without one): 33 snippets with heredocs,
  nowdocs, interpolation, `?>` in strings and comments, alternative syntax, attributes,
  declarations, `goto`, inline HTML, unterminated code, odd titles, and odd `@input` labels, each
  as a Laravel command, a Laravel Zero command, a Pest test, and two PHPUnit tests, all pass
  `php -l`. Generated commands run against stand-ins for `Command` and `dump()` print the same
  strings as the snippet run directly (also when the snippet is indented), read arguments and
  options with the right types, declare functions and classes before use, and keep inline HTML.
- By hand (not part of the test suite), in a scratch copy of the bundled Laravel 13 sandbox: a
  generated command was listed by `php artisan list`, ran with an argument, an option, and a
  flag, and showed its arguments and options in `php artisan help`; a generated PHPUnit test ran
  and was reported as risky (no assertions yet).
- Debug app screenshots in [#141](https://github.com/filipac/runlet/pull/141) (scratch data and a
  scratch project). The save panel itself isn't in them: it is AppKit's own and can't be drawn by
  the snapshot steps, which write the file directly (`promote:artisan:<file>`, `promote:test:<file>`).
