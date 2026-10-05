# Format Code

**Edit ▸ Format Code** (<kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd>) formats the current PHP tab in the coding style you choose: PER, PSR-12, or Laravel. It uses the [Mago](https://github.com/carthage-software/mago) formatter, which is bundled with Runlet, so it works without PHP on your Mac. Formatting never runs your code and never connects to the tab's target.

```php
// Before
$users=User::where('active',true)->get()->map(fn($u)=>[ 'name'=>$u->name,'email'=>$u->email ]);

// After, in the Laravel style
$users = User::where('active', true)->get()->map(fn ($u) => ['name' => $u->name, 'email' => $u->email]);
```

## Formatting a Tab

Choose **Edit ▸ Format Code**, press <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd>, or run **Format Code** from the command palette.

- **The whole tab.** Mago formats whole files, so a selection doesn't limit it.
- **One undo step** (**Undo Format Code**). Only the changed part of the text is replaced, so the caret stays on the same code and the scroll position stays.
- **Snippets without `<?php`** work, and a last expression without a semicolon keeps it that way.
- **Magic comments** (`//?`, `/*?*/`, `/*?->…*/`, `/*?.*/`) stay after the same code. When formatting would change what one of them shows, the code is left as it is, and the tab says which comment and line.
- **A syntax error** leaves the code unchanged and shows the formatter's message above the editor, such as "Expected one of `RightBracket`, found `Semicolon`". It goes away with your next edit, or **Dismiss**.
- **SQL tabs** aren't formatted: the command is disabled there, with the reason in the palette and the menu item's tooltip.
- **It's an edit,** like typing, except that it never starts the sandbox's [auto-run](sandbox-auto-run.md).

> [!NOTE]
> Mago removes parentheses it considers redundant. So `$a + ($b /*?*/)` would become `$a + $b /*?*/` and show `$a + $b` instead of `$b`. Runlet leaves such code as it is.

## Settings

Choose the style in **Settings ▸ Editor ▸ Formatting**:

| Setting | Default | What it does |
| --- | --- | --- |
| **Style** | PER Coding Style | PER Coding Style, PSR-12, or Laravel (Pint), which writes `fn ($x)`, `! $a`, and `new Foo`. |
| **Quotes** | Single | Plain strings get single or double quotes. Strings that need theirs (escapes, interpolation, or the other quote inside) keep them. |
| **Format before run** | Off | Run and Profile Run format a PHP tab first, as one undo step, and then run the formatted code. See below. |

Indentation follows **Settings ▸ Editor ▸ Indentation** (tab width, and spaces or tabs). The PHP version of the tab's target decides where trailing commas may go: in parameter lists only from PHP 8.0. For a target whose version Runlet doesn't know yet, formatting assumes PHP 7.4, whose output works on later versions.

**Format before run** never applies to Run Selection, the sandbox's auto-runs, SQL tabs, or code you open, import, or restore. If the code can't be formatted, it runs as written, and a syntax error is left for the run to report.

A project's `mago.toml`, `pint.json`, or `.php-cs-fixer.php` isn't used: snippets aren't project files, and running a project's own formatter would need PHP on the target.

## For developers

Format Code was added under [#36](https://github.com/filipac/runlet/issues/36).

### How It Works

`SnippetFormatter` (`Packages/RunletKit/Sources/RunletLanguage/SnippetFormatter.swift`) sends the text to `Contents/Helpers/mago format --stdin-input` with a config file Runlet writes in a new private temporary directory (`0700`), which is also the working directory, `$HOME`, and `$XDG_CONFIG_HOME` of the process, so no other Mago config applies. The code is never written to a file. The process gets a minimal environment, `--no-extensions`, one thread, and ten seconds. Runlet adds `<?php` for the formatter to a snippet without one and removes it again.

The output is then checked with a small PHP scanner (`PHPScanner.swift`): every comment must still be there, in order and with the same text (Mago writes `# note` as `// note`), and every magic comment must follow the same name, variable, or literal; a `/*?…*/` inside parentheses must still be inside them, and a `//?` on a line of its own must stay on its own line. When a check fails, the text isn't changed. `FormattingEdit` is the editor's one replacement and caret.

### Bundled Formatter

| | |
| --- | --- |
| Formatter | Mago 1.51.2 ([release](https://github.com/carthage-software/mago/releases/tag/1.51.2)) |
| Licence | MIT OR Apache-2.0; Runlet ships the MIT text as `Contents/Resources/Licenses/Mago-LICENSE.txt` |
| aarch64 SHA-256 | `13125481a4a039b92d520c04d4f395c90dd0223284c976c1c3e447b0bbdbda07` |
| x86_64 SHA-256 | `bcbac16d24ef6c6b7df951ecfac2064954bd900292ae7c8afb5222cdd7fe753d` |
| Size | 54 MB universal |

`scripts/fetch-mago.sh` downloads both release tarballs, verifies their checksums, and builds the universal binary at `Resources/Formatter/mago` (ignored by git). The build phase runs it when the binary is missing, copies the binary to `Contents/Helpers/mago`, and signs it like PHPantom. `scripts/package.sh` checks both architectures, the version, and the licence. The packaged self-test (`Runlet --self-test`) formats a snippet with the bundled binary.

PHPantom has Mago's formatter built in, but Runlet doesn't use `textDocument/formatting`: Runlet's PHPantom configuration turns every formatter off so that nothing needs host PHP, and PHPantom picks the project's Pint or PHP-CS-Fixer (which need PHP) when a project lists them. A separate binary formats the same way for every target, before the language server has started, and when completion is turned off.

### Validation

`SnippetFormatterUnitTests` (17 tests) cover the scanner (strings, heredocs, interpolation, inline HTML, `#[` attributes), the final-semicolon and `<?php` handling, the comment checks (accepted moves and each refused one), the config and PHP version, parse-error messages, the editor edit and caret, and the wrapper with a fake formatter executable: its arguments, private directory and environment, syntax errors, a hanging formatter stopped by the timeout, a missing binary, and output that moves a magic comment.

`SnippetFormatterMagoTests` (8 tests) run the real `Resources/Formatter/mago` and are skipped without it: a tagless fragment, last expressions without a semicolon, a snippet with every magic comment form, the refused `$a + ($b /*?*/)`, syntax errors, idempotence (formatting twice gives the same text), the opening tag and final line break, and style, quotes, tabs, and PHP 7.4 versus 8.3 trailing commas. `PersistenceTests.formattingSettingsDefaultOffAndRoundTrip` checks that settings saved before this change load with Format before run off.

All 26 passed with Mago 1.51.2 on arm64. The Debug app's self-test passed its formatter check, and its `editor-check` step (`EditorDebugCheck`) checks on a hidden editor that Format Code is one undo step after typing (**Undo Format Code**, then redo, then the typing's own undo), keeps the caret on its code, and changes nothing for already formatted text. The app was checked with the Debug snapshot steps on a scratch data directory (screenshots in [#155](https://github.com/filipac/runlet/pull/155)); no XCUITest was added or run for this change.

Reproduce the screenshots with `python3 scripts/format-code-screenshots.py /path/to/Runlet.app /path/to/output` against a Debug build. It uses a temporary `RUNLET_DATA_DIR` under `/private/tmp`. Its first launch runs nothing; its second turns on Format before run and runs only the seeded snippet in Runlet's own sandbox, which shows the code formatted before the run and the magic comments' values on their lines.
