# Compatibility and prototype-gate evidence

Remaining Laravel inference gaps and additional compatibility validation are tracked in [#55](https://github.com/filipac/runlet/issues/55) and [#54](https://github.com/filipac/runlet/issues/54). This file records its original evidence; the documentation audit did not rerun it.

Recorded 2026-10-02 on macOS 27.0 (arm64), Xcode 27.0, Swift 6.4, Docker 29.4.0.

## PHP runner

Framework detection and project drivers (`.runlet/*Driver.php`) are documented in
[drivers.md](drivers.md).

| Item | Choice / result |
| --- | --- |
| Supported target PHP | 7.4 – 8.5 (decision: PHP 7.4 floor) |
| Parser | nikic/php-parser 5.9.0, scoped to `RunletVendor\PhpParser`, bundled into `Resources/Runner/dist/runlet-runner.php` |
| Transport | Whole runner streamed to `php` on stdin; events are nonce-framed records on stdout (`0x1E RL1:<nonce>:<len>:<json>\n`). No files are written into projects or containers, so read-only filesystems and non-root users work. |
| Verified runtimes | Herd PHP 7.4.33 and 8.4.25 locally; `php:7.4-cli` (uid 1000, read-only root FS, read-only app mount), `php:8.4-cli`, `php:8.2-cli-alpine` via `docker exec` |
| Laravel | 13.34.0 (pinned sandbox + fixture app): bootstrap ≈ 40 ms, full run ≈ 90–140 ms locally; ≈ 150–250 ms via `docker exec` |
| Required extensions | `tokenizer` for final-expression capture (falls back to running without implicit results, with a notice). `json` and `pcre` are core. No `pcntl`/`posix` needed. |
| Run inspector | `Inspector.php` keeps PHP 7.4 syntax; the DBAL 4 middleware (PHP 8.1 syntax) is evaluated only when DBAL 4 is in use. Verified with Laravel 13.34 (queries, mail, interception, logs, previews), illuminate/database 8.83 + illuminate/events on PHP 7.4 and 8.4, illuminate/database 13.34 without events (query-log fallback), Doctrine DBAL 3.10 and 4.5, WordPress 7.1 on SQLite, and Symfony 8.1 responses (`InspectorTests`). |
| `dump()`/`dd()` | Hooks the project's VarDumper and any VarDumper behind a pre-existing global `dump()` (e.g. php.ini `auto_prepend_file` tools such as global Ray, including php-scoper aliases). Without var-dumper, Runlet defines `dump()`/`dd()`. |

### Benchmarks and Profile Run ([#41](https://github.com/filipac/runlet/issues/41))

| Item | Requirement / result |
| --- | --- |
| `Runlet\bench()` | Every target: plain PHP 7.4+ in the runner, no extension. `hrtime(true)` timing; memory peaks need PHP 8.2+ (`memory_reset_peak_usage()`), older PHP reports the peak only when it rose above the process's earlier peak. Verified on Herd PHP 8.4.25 and 7.4.33 (host) and PHP 8.4.26 in Docker. |
| Laravel `Benchmark::dd()` | Recognized from its dump on Laravel 13.34 (sandbox and `laravel-app` fixture). `Benchmark::measure()` and `value()` are not observed (they only return numbers); use `Runlet\bench()`. |
| Profile Run | Needs the **Excimer** extension in the target's PHP ([mediawiki.org/wiki/Excimer](https://www.mediawiki.org/wiki/Excimer); Linux, BSD, or macOS; packages `php-excimer` from deb.sury.org or remirepo, `pie install wikimedia/excimer`, or `pecl install excimer`). Verified with Excimer 1.2.6 on PHP 8.4.26 (`php:8.4-cli` with `pecl install excimer`, the runlet-fixtures `profiler` service). Wall-clock sampling at 1 ms by default; CPU-time sampling is not available on macOS. |
| SPX | Detected (version shown) but not used for Profile Run: SPX profiles only processes started with `SPX_ENABLED=1` and writes reports to `spx.data_dir` or stderr, with no API that hands them to the running script. Checked with SPX 0.4.22. |
| Detection | PHP discovery (with the PHP's own php.ini, `auto_prepend_file` off), the Docker profile Test, SSH Test Connection, and every run's `started` frame. |
| Runlet's own PHP | The static build (`scripts/php-runtime/craft.yml`) has neither Excimer nor SPX, so Profile Run is disabled there with the reason. |

### Runlet's own PHP ([#2](https://github.com/filipac/runlet/issues/2))

When no installed PHP fits, Runlet offers to download its own PHP (Settings ▸ PHP, or a banner
above a sandbox or local tab). It is a static PHP CLI built with
[static-php-cli](https://github.com/crazywhalecc/static-php-cli) from
`scripts/php-runtime/craft.yml` by `.github/workflows/php-runtime.yml`, one archive per CPU type,
published as a pre-release tagged `php-<version>-r<build>`.

| Item | Value |
| --- | --- |
| Version | PHP 8.5.8 (`RunletPHPRelease.current`, build `r1`) |
| Extensions | bcmath, bz2, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd, gmp, iconv, intl, mbstring (with mbregex), mysqli, mysqlnd, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix, readline, redis, session, simplexml, soap, sockets, sodium, sqlite3, tokenizer, xml, xmlreader, xmlwriter, zip, zlib |
| Not included | Xdebug and other Zend extensions, imagick, swoole, APCu, and PECL extensions beyond redis; projects that need them should use an installed PHP. |
| Location | `~/Library/Application Support/Runlet/PHP/8.5.8-r1/bin/php` (with `licenses/` and `README.txt`) |
| Trust | Downloaded only on request, checked against the SHA-256 pinned in the app, and must run and report the expected version before it is installed. |

Known limitations:
- `var_dump`/`print_r` stay textual (not parsed into structures), by design.
- Snippet child processes: local Stop signals the runner's process group (verified). In an
  existing container (`docker exec`), Stop signals the runner PID only; children a snippet spawns
  inside the container are not guaranteed to stop (not tested). The Docker sandbox is different:
  Runlet owns that container (`docker run --rm --init`), so Stop kills the whole container.
- Cancellation in an existing container requires `posix_kill` or `/bin/sh` + `exec()` in the
  container; if neither exists, Stop reports that the PHP process may still be running.

### Magic comments ([#10](https://github.com/filipac/runlet/issues/10))

Recorded 2026-10-03 with Herd PHP 8.4.25 and 7.4.33, the Laravel 13.34.0 sandbox, the
`runlet-fixtures` `restricted` container, and the disposable SSH fixture.

| Form | Shows |
| --- | --- |
| `//?` at the end of a line | The value of what ends right before it on that line: an expression statement's value (an assignment's assigned value; `$i++; //?` shows `$i` after the increment), a `return`'s value, or `echo`'s argument (a list when there are several). After a sub-expression on a line of a multi-line expression, that sub-expression; after a trailing comma, the item before it. On a line without a value (`foreach (…) { //?`, `} //?`, a line of its own) it shows `✓` when the line is reached. |
| `/*?*/` | The largest expression that ends right before it: `$a * $b /*?*/ + 1` shows `$a * $b`, and `$a + ($b /*?*/)` shows `$b`. After an arrow function's body, `yield`, `print`, or `throw`, their operand. After a statement (`foo(); /*?*/`), its value. |
| `/*?->chain*/`, `/*??->chain*/` | A projection of the value before it (`/*?->count()*/`, `/*?->first()->name*/`); the code still gets the value itself. A projection is user code: it runs only for the hits whose values are sent (so it may query a database), sees variables by value, and an exception it throws is shown instead of a value. |
| `/*?.*/` | Milliseconds since the previous `/*?.*/` hit of the run, or since the snippet started. After an expression, measured once the expression has its value; between statements, at that point. |

A line that runs more than once shows `×N` and the latest value; hovering (or Edit ▸ Show
Inline Value) shows the value tree and every hit. The first 100 hits of each comment carry
values; later ones are counted, with a value sampled about four times a second, and the final
count arrives when the run ends. Values are bounded (depth 5, 100 children per level, 8 KiB
strings, 256 KiB each) and stop after 16 MiB per run (counts continue). They stream while the
code runs on every target (verified locally, in a container, and over SSH). Text that looks like
a magic comment inside a string, heredoc, another comment, or inline HTML is not one; `#?` and
`//? note` are ordinary comments.

**What the code does doesn't change.** Probes are calls inserted around expressions at byte
offsets on the same lines; the code is never re-printed. Every expression is still evaluated
once and in order; references are kept (by-reference arguments, `=&`, `foreach (… as &$v)`,
by-reference returns and generators); nullsafe chains still short-circuit; `match`, ternaries,
string interpolation, named arguments, `fn`/`static fn`/closures, generators, destructuring,
compound assignments, and `??=` behave the same. `MagicCommentTests` runs each fixture with and
without its magic comments and requires the same output, results, dumps, and errors (PHP 8.4,
plus a PHP 7.4 subset).

**Not shown.** The code runs as written, one notice lists them, and the line shows a short
reason (the full one on hover):

- assignment and destructuring targets (`$x /*?*/ = 1`, `[$a /*?*/, $b] = …`), `foreach`
  variables, `global`/`static`/`unset`, parameters, and closure `use` variables;
- a variable, element, or property checked by `isset()`, `empty()`, or the left side of `??`;
- constant expressions: parameter and property defaults, constants, enum cases, attributes;
- the start of a `"{$…}"` interpolation (put the comment after the string);
- by-reference array items (`[&$x /*?*/]`);
- a nullsafe chain followed by a plain link (`$a?->b() /*?*/ ->c()`): put it before `?->` or
  after the chain;
- a variable, element, or property passed to a method on an object, through a dynamic name, or
  to a class Runlet hasn't loaded, because the parameter might be by reference (classes are never
  autoloaded to find out). Other expressions passed there (`$o->m($a + 1 /*?*/)`) are fine, and
  so are arguments of functions and of loaded or snippet-declared classes;
- projections and `/*?.*/` around a value taken by reference, and `exit` without an argument.

Known limitations: a call that returns by reference, passed straight to a by-reference parameter
of a method Runlet can't resolve, would lose the reference when wrapped (`$o->m(ref() /*?*/)`);
with soft wrap on, a long line may leave no room for its values (hover or Show Inline Value still
shows them); without soft wrap, values after long lines may need horizontal scrolling.

The next run clears the values. Until then, a line edited since the run loses its values, and
lines above or below an edit keep theirs, moved with their text. Values never start a run, and
opening, importing, or restoring code never runs it.

**Settings ▸ General ▸ Magic Comments** (both on by default):

- *Show values of magic comments*: turned off, magic comments are ordinary comments. Runlet adds
  nothing to the code it runs on any target (no probes, so no overhead and no notices about
  placements), and the editor doesn't highlight them or show values.
- *Show values while the code runs*: turned off, the values appear together when the run ends,
  including a failed or stopped run. The run's output still streams as before.

## PHPantom 0.10.0 prototype gate

Binary: release tarballs for `aarch64-apple-darwin` and `x86_64-apple-darwin`, SHA-256 pinned in
`scripts/fetch-phpantom.sh`, combined into a universal binary. Launched with `PATH=/usr/bin:/bin`
(no host PHP) and `XDG_CONFIG_HOME` pointing to an app-owned directory.

| Gate | Result | Evidence |
| --- | --- | --- |
| 1. Tagless unsaved scratch document with project completion, no disk writes | Pass. An in-memory `file://<root>/.runlet-scratch/tab-<id>.php` URI resolves against the real root; nothing is created on disk. | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles` |
| 2. Positions/edits across synthetic tag and Unicode | Pass. Synthetic `<?php\n` occupies its own line, so only lines shift; both sides use UTF-16. Import `additionalTextEdits` map to editor line 0. | `importEditsMapBackToEditorCoordinates`, `hoverSignatureHelpAndDiagnosticRangesWithUnicode`, `MappingTests` |
| 3. Different PHP target, existing `.phpantom.toml`, vendor files, no repo/global changes | Pass. Per-session `[php] version` is written to the app-owned config home; the project's `.phpantom.toml` is read but never modified. | `workspacesAreIsolatedAndRespectProjectConfiguration` |
| 4. Suppress external analyzers/formatters | Pass. App config sets `phpstan/phpcs/mago` commands and formatter paths to `""` and disables workspace diagnostics. Control experiment: with an empty config plus a project `.phpantom.toml` `workspace = true`, PHPantom launched the project's `vendor/bin/phpstan`; with Runlet's config it did not. A project that explicitly sets a tool **command** in its own `.phpantom.toml` would still override this (explicit project opt-in). | `externalAnalyzersAreNotLaunchedImplicitly` |
| 5. Isolation and crash recovery | Pass. One process per workspace key; a killed server restarts automatically and re-opens documents from the client's copy. | `workspacesAreIsolatedAndRespectProjectConfiguration`, `crashedServerRestartsAndRestoresDocuments` |

Server capabilities advertised by 0.10.0: completion (+resolve), hover, signature help,
definition, type definition, implementation, references, document highlight/symbols, workspace
symbols, code actions, code lens, formatting, on-type formatting, rename, document links,
folding, semantic tokens, inlay hints, selection ranges. Runlet's MVP uses completion, resolve,
hover, signature help, and pushed diagnostics.

Observed quirks:
- Completion `insertText` uses snippet syntax (`PriceFormatter()$0`) even when the client
  declares `snippetSupport: false`; Runlet converts snippets to plain text (`SnippetText`).
  Required parameters are placeholders (`split(${1:\$pattern})$0`, `DateTimeZone(${1:\$timezone})$0`
  after `new`); methods with only optional parameters get `trim()$0` but list them in the label
  (`trim($characters = ...)`); built-in functions get `array_map()$0` with no parameter list in
  the label. Calls are inserted as `name()` without placeholder text (`CompletionInsertion`).
- Startup on the Laravel fixture: initialize ≈ 0.7 s cold, completion ≈ 20 ms.

### Laravel completion (scenario 15; PHPantom 0.10.0, Laravel 13.34.0)

Recorded by `Packages/RunletKit/Tests/RunletLanguageTests/LaravelCompletionTests.swift` (15
tests, all passing). The tests assert what PHPantom actually returns. Where it falls short, the
test asserts the observed result and carries an `// Unsupported in PHPantom 0.10.0:` comment, so
a PHPantom upgrade that changes the behavior fails the test and this table must be updated.

Workspaces used:

- **Fixture:** `Tests/Fixtures/laravel-app`. It is a copy of the pinned sandbox template (same
  `vendor/`, config, and `User` model) plus `App\Models\Widget` (`$fillable`, `casts()` with
  `'price' => 'integer'`, `scopeExpensive`, a `widgets` migration) and `App\Services\PriceFormatter`.
  Results on the fixture therefore also describe the sandbox.
- **Model workspace:** the fixture has no relations, and its only cast matches its column type.
  `ModelWorkspace` (in the same test file) builds a temporary project whose `vendor` is a symlink
  to the fixture's, with `Gadget`, `Part`, and `Gizmo` models and an `AppServiceProvider` macro.
  Migrations in this temporary workspace were not picked up for attribute inference (cause not
  investigated), so its tests rely on casts and relations only.

All snippets are tagless, as typed in a scratch tab, and use runtime aliases (`DB`, `Cache`,
`Str`) without `use` statements. Test names below are `LaravelCompletionTests.<test>`.

| Area | Case (snippet → expectation) | Result | Test |
| --- | --- | --- | --- |
| Facades | `DB::table('widgets')->` → query-builder methods (`where`, `orderBy`, `get`, `first`, `pluck`, `paginate`); `get` is `Collection<int, stdClass>`. The fully qualified facade gives the same list. | Supported | `facadeQueryBuilderChainOffersBuilderMethods` |
| Facades | `Cache::` → `get`, `put`, `remember`; hover on `Cache::get(` shows the facade's `@method` signature | Supported | `cacheFacadeStaticMethods` |
| Facades | `Str::` → `slug`, `limit`; hover shows the method's PHPDoc summary | Supported | `strStaticMethods` |
| Facades | Return types through facades: `Cache::store()->get`, `DB::connection()->table`, `Http::get(…)->json` | Supported | `facadeAccessorReturnTypesChain` |
| Eloquent scopes | `scopeExpensive` is offered as `expensive()` on `Widget::query()->` (detail `Builder<Widget>`) and statically (`Widget::exp` → `expensive`). `Widget::query()->expensive()->` → `get`, `first`, `where`; `…->get()->first()->` → `price`, `name` | Supported | `localScopeIsOfferedAndKeepsTheBuilderChain` |
| Eloquent builder | `Widget::where('price', '>', 1)->` → `orderBy`, `with`, the scope. Terminal calls resolve to the model: `->orderBy()->first()`, `->with()->where()->get()->first()`, `->latest()->paginate()->first()`, `findOrFail`, `firstWhere`, `create`. Dynamic `whereName('x')->` is treated as a builder call. Item details show the unsubstituted template (`first` is `TModel\|null`), but the chain itself resolves. | Supported | `builderChainFromStaticWhere` |
| Eloquent relations | Relations with a generic PHPDoc (`@return HasMany<Part, $this>`) or with no return type (`return $this->hasMany(Part::class)`) resolve the related model through the property (`->partsGeneric->first()->`), after `with()`, and as a relation builder (`->partsGeneric()->` → `where`, `get`, `first`). An untyped `belongsTo` resolves the parent model, including its casts. | Supported | `relationsResolveTheRelatedModel` |
| Eloquent relations | A relation declared with only the native return type (`public function parts(): HasMany`, the style of `make:model` and the Laravel docs) loses the related model: `->parts` is `Collection<Model>`, and `->parts->first()->` offers only base `Model` members. | **Unsupported** | `relationsResolveTheRelatedModel` |
| Attributes | Columns from migrations, with types: `Widget::first()->` → `price` (`int`), `name` (`string`), `id` (`int`), `created_at` (`Carbon`); hover on `$w->price` shows `int` | Supported | `modelAttributesFromMigrationWithTypes` |
| Casts | A cast that changes the type is reported with its source (`source: cast …`): `datetime` → `Carbon` (sandbox `User::email_verified_at`), `boolean` → `bool`, `array` → `array`, `decimal:2` → `float`, `integer` → `int`. Read from a `casts()` method whose array has a trailing comma, and from the `$casts` property. | Supported | `castsDefineAttributeTypes`, `modelAttributesFromMigrationWithTypes` |
| Casts | The **last** entry of a `casts()` return array is ignored when it has no trailing comma (single-line or multi-line). The fixture's `['price' => 'integer']` is such an entry: `price` is still `int`, but from the migration column (`source: database column`). An attribute that exists only in such an entry is unknown (no completion, no hover). The `$casts` property is not affected. | **Partial** | `castsDefineAttributeTypes`, `modelAttributesFromMigrationWithTypes` |
| Collections | `Widget::all()->first()->` → `price` (`int`), `name`; `Widget::all()` is `Collection<int, Widget>`. The element type survives `filter(fn …)`, `sortBy()->values()`, `cursor()`, and `lazy()`, and reaches closure parameters (`map(fn ($w) => $w->`, `each(function ($w) { $w-> })`) and `foreach` variables. | Supported | `eloquentCollectionElementType` |
| Collections | `Widget::all()->keyBy('id')->first()->` loses the element type: only base `Model` members, no `price` | **Unsupported** | `eloquentCollectionElementType` |
| Collections | `collect([new App\Services\PriceFormatter])->first()->` → exactly `format` (`string`); hover is `PriceFormatter\|null` | Supported | `collectHelperElementType` |
| Helpers | `app(App\Services\PriceFormatter::class)->` and `resolve(…::class)->` → exactly `format`. `str('a')->slug`, `now()->format`, and `auth()->user()->` (the `User` model's `email`) also resolve. | Supported | `containerHelpersResolveClassStrings` |
| Helpers | `config('app.` → configuration keys as full dotted labels (`app.name`, `app.timezone`, nested `app.maintenance.driver`); `config('` lists keys from every config file (`database.default`, `cache.default`). Requested explicitly, as with Ctrl-Space in the editor, because `'` and `.` are not completion triggers. | Supported | `configKeyCompletion` |
| Signature help | `Str::limit('abc', ` → `($value, $limit = 100, $end = '...', $preserveWords = false): string`, four parameter ranges, per-parameter docblock types (`string`, `int`, `string`, `bool`), active parameter 1. The label omits the method name (cosmetic). | Supported | `strLimitSignatureHelp` |
| Macros | A macro registered in the same snippet (`Collection::macro('shout', …); collect()->sh`) is offered | Supported | `macros` |
| Macros | A macro registered elsewhere in the project (`Collection::macro('whisper', …)` in `AppServiceProvider::boot`) is not offered | **Unsupported** | `macros` |
| Model methods | `$w->save`, … | Supported | `PHPantomTests.taglessScratchCompletionUsesProjectRootWithoutWritingFiles` |
| Classes | Class completion with an automatic `use` import mapped to editor line 0 | Supported | `PHPantomTests.importEditsMapBackToEditorCoordinates` |

Not covered yet:

- A real user application (local or Docker) rather than the sandbox-derived fixture, which plan
  scenario 15 asks for.
- The rendered editor: only array-function completion is checked by a UI test
  (`RunletUITests.testCompletionPopupForTaglessSnippet`). The Laravel cases above are checked at
  the language-service level, through the same scratch-document mapping the editor uses.
- Other dynamic members (custom Eloquent builders, attribute accessors, `Attribute` mutators,
  `__call` forwarding in user classes, packages that register macros at runtime).
