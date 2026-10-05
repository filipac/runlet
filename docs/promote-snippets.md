# Promote a Snippet

Scratch code that works often belongs in the project. **File ▸ Save as Artisan Command…** and **File ▸ Save as Test…** turn the current tab's code into an Artisan command class, or a Pest or PHPUnit test, in the tab's project, for you to review and commit.

Runlet only writes the file, and only where you choose in a save panel. It runs nothing: no Artisan, no tests, no PHP.

## Saving a Command or a Test

1. Write the snippet, and select part of it if you want only that part. With a selection, the tab's `use` imports come along.
2. Choose **File ▸ Save as Artisan Command…** or **File ▸ Save as Test…**. Both are also in the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>), and in the context menu of personal and project snippets in the Snippets panel.
3. Pick the folder and file name in the save panel, and save.

After saving, a sheet shows where the file went and any TODOs in it, with **Open in** your editor (**Settings ▸ Editor ▸ External Editor**) and **Reveal in Finder**.

![The sheet after Save as Test…: NewUserTest.php saved in tests/Feature of the shop project, with Reveal in Finder, Open in PhpStorm, and Done](screenshots/promote-snippets/save-as-test-light.webp#gh-light-mode-only)
![The sheet after Save as Test…: NewUserTest.php saved in tests/Feature of the shop project, with Reveal in Finder, Open in PhpStorm, and Done](screenshots/promote-snippets/save-as-test-dark.webp#gh-dark-mode-only)

### Where the File Goes

The save panel opens in the tab's project folder:

- **A command** goes to `app/Console/Commands` (`app/Commands` on Laravel Zero).
- **A test** goes to `tests/Feature`.

When that folder doesn't exist, the panel opens in the nearest one that does, and **New Folder** creates the rest. The file name comes from the tab's title or the snippet's label, such as `RefundOrder.php` or `RefundOrderTest.php`. The panel asks before it replaces a file, and stays open on a name that can't work:

- a name that isn't a PHP class name (letters, digits, and underscores, starting with a letter, and not a reserved word);
- a test file whose name doesn't end in `Test.php`, since Pest and PHPUnit only run those;
- a name the snippet already imports, such as `Order.php` with `use App\Models\Order;`.

The class name is the file name, and the namespace follows the folder through your `composer.json`'s PSR-4 autoload map (`app/Console/Commands` is `App\Console\Commands`, `tests/Feature/Orders` is `Tests\Feature\Orders`), so the class autoloads where you saved it.

### When They're Available

| Target | Save as Artisan Command… | Save as Test… |
| --- | --- | --- |
| Local project | Laravel, Lumen, or Laravel Zero | Yes |
| Docker profile with a local source folder | Laravel, Lumen, or Laravel Zero | Yes |
| SSH profile with a local folder (its checkout on your Mac) | Laravel, Lumen, or Laravel Zero | Yes |
| The sandbox, or a profile without a local folder | No | No |
| SQL tabs | No | No |

A disabled command says why in the command palette and in its menu item's tooltip. Runlet knows the framework from the target's last run, or from the project's files; a project that hasn't been detected yet counts as Laravel when it has an `artisan` file.

## What the Generated Code Looks Like

Take this snippet with [inputs](snippet-inputs.md):

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

### As an Artisan Command

**Save as Artisan Command…** writes `app/Console/Commands/RefundOrder.php`, in the style of `php artisan make:command`:

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

The file also has `<?php`, the namespace, the imports, and the docblocks of Laravel's stub.

### As a Test

**Save as Test…** writes a Pest test when the project uses Pest (`pestphp/pest` in `composer.json`, `vendor/pestphp/pest`, or `tests/Pest.php`). Otherwise it writes a PHPUnit class that extends the project's `Tests\TestCase`, or `PHPUnit\Framework\TestCase` when there is none:

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

## How the Code Changes

- **The opening tag and imports.** `<?php` goes, and `use` lines move to the file's imports, sorted, with the base class's (`Illuminate\Console\Command`, `Tests\TestCase`). When an import already takes the base class's name, the class extends it by its full name instead.
- **Declarations.** Named functions, classes, interfaces, traits, enums, and `const` at the top level move before the class (or the `test()` call). A snippet declares them before its code runs, while inside a method they would only exist once reached (and `const` not at all). Closures, and declarations inside `if` blocks, stay where they are.
- **`declare(strict_types=1)`** is kept when the snippet declares it, and added when the target runs with strict types (in Settings, or the project's own option).
- **`namespace`.** A `namespace` statement or block is removed, with a TODO: the file has its own.
- **Magic comments** (`//?`, `/*?*/`, `/*?->…*/`, `/*?.*/`) are removed, since they mean something only in Runlet's editor. Other comments stay.
- **The result.** The value Runlet would show as the result (the last expression, or a final `return`) is passed to `dump()` in a command. In a test, it's assigned to `$result` with a TODO to assert it, so the test doesn't pass or fail by accident: until you add assertions, Pest and PHPUnit report it as risky. When the last statement is an assignment (`$total = …;`), its variable is used instead, and a final `dump()` or `dd()` stays as it is.
- **Indentation.** The code is re-indented into the method or closure. Lines inside a string, heredoc, nowdoc, or inline HTML keep their exact text, so no string changes, and flexible heredocs stay valid.
- **Runlet's helpers,** such as `Runlet\bench()`, exist only when Runlet runs code; using one adds a TODO.

### Inputs

`@input` lines leave the docblock.

- **In a command,** an input without a default is a required argument. One with a default or choices is an option, read with its default; choices are listed in its description, not enforced. A `bool` is a flag, `--no-<name>` when it defaults to true. `int` and `float` values are cast. Option names are kebab-case and avoid the console's own (`--env`, `--verbose`, …).
- **In a test,** each input gets its default (`false` for a `bool`), or a typed empty value with a TODO. A placeholder assignment in the snippet keeps its value.
- **Declarations Runlet can't read** are listed as TODOs.

## For developers

Promotion was added under [#39](https://github.com/filipac/runlet/issues/39) (N36), using snippet inputs from [#14](https://github.com/filipac/runlet/issues/14).

- The code generation is `SnippetPromotion.artisanCommand` and `SnippetPromotion.test` (`SnippetPromotion.swift`, RunletCore); `ProjectLayout` reads `composer.json` (PSR-4 namespaces for a folder, Pest) and `tests/TestCase.php`. See [Architecture](architecture.md).
- A `<?php` that reopens PHP after inline HTML keeps its exact text too, and a flexible heredoc's closing marker keeps its indentation.

**Validation.**

- `SnippetPromotionTests` (23 tests): whole commands, Pest and PHPUnit tests, results, assignments and `return`, imports and groups, selections with the tab's imports, namespaces, declarations, magic comments, heredocs and multi-line strings, inline HTML, inputs as arguments and options, escaping of titles and labels, names, PSR-4 namespaces, and Pest detection.
- `SnippetPromotionPHPTests` (5 tests, with a local PHP; skipped without one): 33 snippets with heredocs, nowdocs, interpolation, `?>` in strings and comments, alternative syntax, attributes, declarations, `goto`, inline HTML, unterminated code, odd titles, and odd `@input` labels, each as a Laravel command, a Laravel Zero command, a Pest test, and two PHPUnit tests, all pass `php -l`. Generated commands run against stand-ins for `Command` and `dump()` print the same strings as the snippet run directly (also when the snippet is indented), read arguments and options with the right types, declare functions and classes before use, and keep inline HTML.
- By hand (not part of the test suite), in a scratch copy of the bundled Laravel 13 sandbox: a generated command was listed by `php artisan list`, ran with an argument, an option, and a flag, and showed its arguments and options in `php artisan help`; a generated PHPUnit test ran and was reported as risky (no assertions yet).
- Debug app screenshots are in [#141](https://github.com/filipac/runlet/pull/141) (scratch data and a scratch project). The save panel itself isn't in them: it's AppKit's own and can't be drawn by the snapshot steps, which write the file directly (`promote:artisan:<file>`, `promote:test:<file>`).
