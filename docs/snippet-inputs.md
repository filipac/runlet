# Parameterised snippets

Implemented in [#14](https://github.com/filipac/runlet/issues/14).

A snippet can declare **inputs** in its docblock. When you open it, Runlet asks for their
values in a small form and puts them at the top of the code as PHP literals. Opening never
runs the code: you check it, then press Run. This is meant for team runbooks, such as
"refund order #…", that otherwise need hand-editing before every use. It is the modern
version of Tinkerwell's dynamic snippets.

## Declaring inputs

Add one `@input` line per value to the snippet's docblock:

```
@input <type> $<name> ["Label"] [= default] [{choice, …}]
```

A support runbook, shared with the team as `.runlet/snippets/refund-order.php`
([project snippets](project-snippets.md)):

```php
<?php
/**
 * @label Refund order
 * @description Refunds an order and records why. Support runbook.
 * @input int $orderId "Order ID"
 * @input float $amount "Amount" = 19.99
 * @input string $reason "Reason" = "duplicate" {duplicate, fraudulent, requested_by_customer}
 * @input string $note "Internal note"
 * @input bool $notify "Email the customer" = true
 */

use App\Models\Order;

$order = Order::findOrFail($orderId);
$order->refund($amount, reason: $reason, note: $note, notify: $notify);
$order->fresh();
```

| Type | Form control | Accepts |
| --- | --- | --- |
| `int` | Text field | A whole number with an optional sign, such as `42`, `-7`, or `1_000`. It must fit PHP's 64-bit range (`-9223372036854775808` to `9223372036854775807`); larger numbers are refused instead of becoming floats. Leading zeros are decimal: `007` is `7`, never octal. |
| `float` | Text field | A decimal number, with an optional exponent: `1.5`, `.5`, `2e-3`, `42`. `INF`, `NAN`, hex floats, and numbers too large for a float are refused; `1,5` asks for a dot. |
| `string` | Text field | Any text, kept exactly as typed (including spaces). It may be empty. |
| `bool` | Checkbox | Defaults may be written `true`/`false` (also `1`/`0`, `yes`/`no`, `on`/`off`). |

- **Name.** A PHP variable name with its `$`. `$this` and `$GLOBALS` are refused. Names are
  case-sensitive, as in PHP.
- **Label.** Optional, in double or single quotes; `\"` (or `\'`) and `\\` escape inside it.
  Without one, the form shows the variable name.
- **Default.** Optional, after `=`. Quote a string default that has spaces. Without a
  default, `int` and `float` fields start empty and must be filled, a `string` starts empty,
  and a `bool` starts unchecked.
- **Choices.** Optional, last, for `int`, `float`, and `string`: `{paid, shipped}` shows a
  menu instead of a text field. Quote a choice that has a comma, a brace, or surrounding
  spaces (`{"on hold", 'a,b'}`). The default must be one of the choices; without a default,
  the first choice is selected.

**Where Runlet looks.** In a project snippet, `@input` lines belong in the metadata docblock;
a docblock with only `@input` lines counts as metadata too, and like the rest of the metadata
it is not part of the opened code. A personal snippet keeps its docblock in its code: write
the `@input` lines in a docblock at the start of the code (after `<?php`, whitespace, or other
comments) and save it with Save as Snippet. In both, every docblock before the first line of
code is read; a docblock after code is ignored.

**Unreadable declarations** are never dropped silently. The Snippets panel marks the snippet
with an orange "input problem" badge (hover it for the reasons), and the form lists each one,
for example `@input integer $limit: “integer” is not an input type. Use int, float, string, or
bool.` The snippet still opens; that input is left out. A variable declared twice keeps its
first declaration.

## Opening one

A snippet with inputs shows the **input form** wherever it opens: double-click or ↩ in the
Snippets panel, Open in Current Tab and Open in New Tab (buttons, context menu, ⌘↩), ⇧↩
(Insert at the cursor), and Open Anything (⌘P, `#` for snippets). The form has one row per
input with its label, a control for its type, its default, and the `$name · type`. A value
that doesn't parse is explained in red and keeps Open disabled. A preview shows the PHP lines
the values become.

- **Open** puts the code where the action says, with the values. It never runs, on any
  target, production included. Opening into the current tab turns its sandbox auto-run
  ([#30](https://github.com/filipac/runlet/issues/30)) off, and new tabs start without it.
  Press Run when you're ready; production targets still ask.
- **Insert** (⇧↩) puts the code with the values at the cursor. It is an edit like typing,
  so it runs only in a sandbox tab where you turned auto-run on, as any edit there does.
- **Cancel** or Escape opens nothing.
- Snippets without `@input` lines open exactly as before, without a form.
- **History** keeps the code that ran, with its values, so restoring an entry never asks again.
- **Copy Code** copies the snippet as it is, without values. **Copy to Personal Snippets**
  copies a project snippet's `@input` lines into a docblock at the start of the personal copy,
  so the copy asks for the same inputs. **Duplicate** keeps them too.

## What the code gets

Each value becomes one line, `$name = <literal>;`:

```php
use App\Models\Order;

$orderId = 1042;
$amount = 12.5;
$reason = 'fraudulent';
$note = 'O\'Neil\'s card was charged twice ($49.90)';
$notify = true;

$order = Order::findOrFail($orderId);
```

- **Where.** After the opening `<?php` tag, docblocks, `declare(…)`, `namespace …;`, and
  single-line `use …;` imports at the top, before the first other line, with a blank line
  after the values. A `<?php` with code after it on the same line gets a line of its own.
- **Placeholders.** If the snippet's opening lines already assign an input, for example
  `$orderId = 0; // set me`, that line is a placeholder: its value is replaced in place
  (`$orderId = 1042; // set me`) and the variable is not assigned a second time. A snippet
  can keep such a line so it still runs as it is (from Copy Code or over MCP). Only
  one-line assignments without another `;`, before the first other statement, count. A later
  assignment is the snippet's own code and is left alone, so it would override the value.
- **Line numbers.** Everything Runlet adds is visible in the tab, and every value is on one
  line, so errors and dumps point at the lines you see. Without placeholders, the snippet's
  own lines move down by the number of values plus one.

## Literals

Runlet writes the literals itself, with `var_export` semantics: each one evaluates to exactly
the value in the form. Tests check every kind against a local PHP (see Validation).

| Value | Literal |
| --- | --- |
| `int` | As `var_export` writes it: `42`, `-7`. `PHP_INT_MIN` is `-9223372036854775807-1`, because `-9223372036854775808` would be a float in PHP. |
| `float` | As `var_export` writes it (`serialize_precision = -1`): the shortest digits that read back as the same float, always with a `.` or an exponent: `12.5`, `1.0`, `0.30000000000000004`, `1.0E+25`, `1.0E-5`, `-0.0`. |
| `bool` | `true` or `false`. |
| `string` | Single-quoted, as `var_export` writes it: only `\` and `'` are escaped (`'O\'Neil'`, `'C:\\path'`). `$`, `{$x}`, and Unicode text are written as they are; single quotes never interpolate. |
| `string` with control characters | Double-quoted on one line, so the value can't spill over lines or hide characters: `\\`, `\"`, and `\$` are escaped, newlines, tabs, and returns become `\n`, `\t`, and `\r`, `\v`, `\f`, `\e` are used, other control characters (including NUL) become `\x00`…`\x1F` and `\x7F`, and C1 controls, line and paragraph separators (U+2028, U+2029), bidirectional controls, and the byte order mark become `\u{…}`. For example, `"line one\nline two"`. |

The only difference from `var_export` is that last row: `var_export` writes a newline as a
real line break inside the quotes and NUL as `'' . "\0" . ''`. The value is the same.

## AI clients (MCP)

`get_snippet` returns a parameterised snippet's `inputs`: for each, `name` and `type`, plus
`label`, `default`, and `choices` when they are declared. Declarations Runlet couldn't read
are in `input_problems`. A client that runs the snippet with `run_php` assigns the variables
itself, and the run asks for approval as usual; see [mcp.md](mcp.md).

```json
"inputs": [
  {"name": "orderId", "type": "int", "label": "Order ID"},
  {"name": "reason", "type": "string", "label": "Reason", "default": "duplicate",
   "choices": ["duplicate", "fraudulent", "requested_by_customer"]}
]
```

## As a command or a test

**Save as Artisan Command…** turns a parameterised snippet's inputs into the command's arguments
and options (an input without a default is a required argument; one with a default or choices is
an option; a `bool` is a flag), with typed casts. **Save as Test…** gives each input its default.
See [promote a snippet](promote-snippets.md) ([#39](https://github.com/filipac/runlet/issues/39)).

## Validation

- **Unit tests** (`Packages/RunletKit/Tests/RunletCoreTests/SnippetInputsTests.swift`):
  declarations (types, labels, defaults, choices, quoting, and each problem message),
  docblock scanning for personal and project snippets, Copy to Personal, unchanged snippets
  without inputs, typed text for every kind (ranges, signs, separators, refused INF/NaN/hex),
  literals and escaping, the code a snippet opens with (placement, placeholders, CRLF), the
  form's state, and the MCP fields.
- **PHP cross-check** (`SnippetInputsPHPTests.swift`, needs a local `php`, run with `php -n`):
  about 9,000 literals (600 ints including `PHP_INT_MIN`/`MAX`, 7,500 floats from every power
  of ten, subnormals, and random bit patterns, and 840 random and hand-picked strings with
  quotes, backslashes, `$`, NUL and other control characters, separators, bidirectional marks,
  combining characters, and emoji) are evaluated by PHP and compared byte for byte (bits for
  floats) with the value they came from, and every literal except control-character strings is
  compared with PHP's own `var_export` text. A second test runs opened code and checks the
  variables and that `__LINE__` matches the line shown in the tab. Checked against PHP 8.4.
- **End to end** (`scripts/snippet-input-screenshots.py <Debug Runlet.app> <output dir>`): a
  Debug build with scratch data and a scratch project opens the project runbook, fills the
  form, checks the new tab's code and that nothing ran or entered History, runs it explicitly
  and checks the output, shows an unreadable declaration and a validation error, cancels
  (nothing opens), and opens a personal snippet whose code would write a file without running
  it. The DEBUG steps are `snippet-open`, `snippet-open-new`, `snippet-input`,
  `snippet-inputs:open|cancel|state`, and `snippet-tab` (`Runlet/App/SnippetInputDebugSteps.swift`).
  Screenshots are in [#122](https://github.com/filipac/runlet/pull/122).
