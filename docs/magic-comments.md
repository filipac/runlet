# Magic Comments

Magic comments show values in the editor while your code runs, without `dump()` calls or temporary variables. Add `//?` to the end of a line, press <kbd>⌘</kbd><kbd>R</kbd>, and the line's value appears after it:

```php
use App\Models\User;

$user = User::find(42); //?
$user->subscriptions; //?
$user->subscriptions /*?->where('active', true)->count()*/;

foreach ($user->subscriptions as $subscription) {
    $subscription->renews_at; //?
}
/*?.*/
```

Magic comments work in every PHP tab, on every target: the Laravel sandbox, local projects, Docker containers, and SSH servers. They never change what your code does.

<!-- screenshot: a snippet with //?, a /*?->count()*/ projection, and a loop line showing ×N, with the values drawn at the end of their lines after a run -->

## The Four Forms

| Comment | Shows |
| --- | --- |
| `//?` at the end of a line | The line's value: an expression, an assignment's value, a `return`, or an `echo`. On a line without a value, `✓` when the line is reached. |
| `/*?*/` after an expression | That expression's value. |
| `/*?->count()*/` | A projection of the value before it. Your code still gets the value itself. |
| `/*?.*/` | Milliseconds since the previous `/*?.*/`, or since the snippet started. |

### The Line's Value

`//?` shows the value of whatever ends right before it on that line:

- **An expression** shows its value. An assignment shows the assigned value, and `$i++; //?` shows `$i` after the increment.
- **A `return`** shows the returned value, and **an `echo`** its argument (a list when there are several).
- **Inside a multi-line expression,** it shows the sub-expression that ends on that line. After a trailing comma, it shows the item before the comma.
- **A line without a value,** such as `foreach (…) { //?`, `} //?`, or `//?` on a line of its own, shows `✓` when the line is reached.

### One Expression

`/*?*/` shows the largest expression that ends right before it, so you can look inside a line:

```php
$total = $price * $qty /*?*/ + $shipping; // shows $price * $qty
$total = $price + ($tax /*?*/);           // shows $tax
```

After an arrow function's body, `yield`, `print`, or `throw`, it shows their operand. After a statement (`sync(); /*?*/`), it shows the statement's value.

### Projections

A projection shows something derived from a value, while your code keeps the value itself. It starts with `->`, or with `?->` when the value may be `null`:

```php
$orders = Order::where('status', 'pending')->get() /*?->count()*/;

$user /*?->subscriptions->first()->plan*/;
$user /*??->team->name*/;
```

A projection is your own code. It runs only for the hits whose values are sent (see [Loops](#loops-and-repeated-lines)), so a projection like `->count()` on a query can run a query of its own. It sees variables by value, and when it throws, the line shows the exception instead of a value and your code goes on.

### Timings

`/*?.*/` shows the milliseconds since the previous `/*?.*/` of the run, or since the snippet started:

```php
$users = User::with('orders')->get(); /*?.*/
$report = $users->map->summary(); /*?.*/
```

After an expression, the time is taken once the expression has its value. Between statements, it's taken at that point. For repeated measurements, use [`Runlet\bench()`](snippet-api.md#runlet-functions).

## Loops and Repeated Lines

A line that runs more than once shows `×N` and its latest value. Hover over the value to see its value tree and every hit, or put the caret on the line and run **Show Inline Value** from the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>).

The first 100 hits of each comment carry their values. After that, Runlet counts the hits and samples a value about four times a second, and the final count arrives when the run ends.

The gutter marks the lines whose magic comments ran, in a warning colour when one of them shows nothing.

## When Values Appear

- **While the code runs.** Values stream in as each line runs, on every target. With **Settings ▸ General ▸ Output** set to **At once**, they appear with the rest of the output when the run ends.
- **With Run Selection.** Values appear on the selected lines, where you see them in the editor.
- **Until the next run.** The next run clears them. An edited line loses its values; the lines above and below keep theirs and move with their text. **Clear Inline Values** in the command palette clears them now.

Values never start a run. Opening, importing, or restoring code doesn't run it either.

## Your Code Runs as Written

Runlet inserts small probes at the comments' positions, on the same lines, and never re-prints your code. So line numbers stay as you see them, every expression is evaluated once and in order, references stay references, and nullsafe chains still short-circuit. `match`, ternaries, string interpolation, named arguments, closures, generators, destructuring, and `??=` behave as they do without the comments.

These aren't magic comments: text that looks like one inside a string, a heredoc, another comment, or inline HTML, and comments such as `#?` or `//? note`.

### Places Runlet Skips

Where a probe could change what your code does, Runlet leaves the comment alone. The code runs as written, one notice in the output lists the skipped comments, and the line shows a short reason (hover for the full one). Runlet skips:

- the targets of assignments and destructuring (`$x /*?*/ = 1`), `foreach` variables, `global`, `static`, `unset`, parameters, and closures' `use` variables;
- a variable, element, or property checked by `isset()`, `empty()`, or the left side of `??`;
- constant expressions: parameter and property defaults, constants, enum cases, and attributes;
- the start of a `"{$…}"` interpolation (put the comment after the string);
- by-reference array items (`[&$x /*?*/]`);
- a nullsafe chain followed by a plain link (`$a?->b() /*?*/ ->c()`): put the comment before `?->` or after the chain;
- a variable, element, or property passed to a method on an object, through a dynamic name, or to a class that isn't loaded yet, because the parameter might take it by reference. Other expressions passed there (`$o->m($a + 1 /*?*/)`) work, and so do arguments of functions and of loaded classes or classes the snippet declares;
- projections and `/*?.*/` around a value taken by reference, and `exit` without an argument.

## Limits

- **Size.** Each value is bounded: depth 5, 100 children per level, 8 KiB per string, and 256 KiB per value. After 16 MiB of values in one run, lines keep counting hits without values.
- **Long lines.** With **View ▸ Wrap Lines** on, a long line may leave no room for its value: hover or use **Show Inline Value**. Without wrapping, values after long lines may need horizontal scrolling.
- **References through unknown methods.** A call that returns by reference, passed straight to a by-reference parameter of a method Runlet can't resolve, loses the reference when wrapped (`$o->m(ref() /*?*/)`).

## Turning Them Off

Turn off **Settings ▸ General ▸ Magic Comments ▸ Show values of magic comments** to make them ordinary comments. Runlet then adds nothing to the code it runs, on any target, and the editor neither highlights them nor shows values.

Other features keep magic comments in mind:

- **Profile Run** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd>) never inserts probes, so its flame graph shows only your code.
- [Format Code](format-code.md) keeps each magic comment after the same code.
- [Save as Artisan Command… and Save as Test…](promote-snippets.md) remove them: they mean something only in Runlet's editor.

## For developers

Magic comments were added under [#10](https://github.com/filipac/runlet/issues/10); the Output setting that decides when their values appear is [#82](https://github.com/filipac/runlet/issues/82), which replaced #10's *Show values while the code runs* switch.

| Piece | Where |
| --- | --- |
| Finding the comments (tokenizer), resolving their expressions (php-parser), inserting probes at byte offsets, and the reasons for skipped places | `MagicComments` in `Resources/Runner/src/MagicComments.php` |
| The runtime: hits, the first 100 values, sampling about every 250 ms, final counts, the 16 MiB budget | `Probe`, in the same file |
| The `probes` and `inline` events, folding hits per editor line, `×N`, and following lines through edits | `InlineValues.swift` (RunletCore): `InlineValues`, `InlineSummary`, `InlineLineTracker` |
| Drawing the values and the hover panel | `InlineValueOverlay.swift` (`InlineValueOverlay`, `InlineValuePanel`) |
| The gutter marker | `LineNumberRulerView.swift` |
| The setting (`AppSettings.magicComments`) and `RunRequest.magicComments` | RunletCore; Profile Run always sends `magicComments: false` |

- The design, the compiler's contexts, and the runtime are in [Architecture ▸ Magic comments](architecture.md#magic-comments-10); the verified forms, placements, and limits, recorded with Herd PHP 8.4.25 and 7.4.33, the Laravel 13.34.0 sandbox, a container, and the SSH fixture, are in [compatibility.md](compatibility.md#magic-comments-10).
- `MagicCommentTests` (RunletExecution) runs each fixture with and without its magic comments and requires the same output, results, dumps, and errors (PHP 8.4, plus a PHP 7.4 subset). `InlineValuesTests` (RunletCore) covers folding and line tracking.
- **Show Inline Value** and **Clear Inline Values** (`edit.showInlineValue`, `edit.clearInlineValues`) are in the command catalog without a menu item or a default shortcut.
