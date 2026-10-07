# Code Navigation

PHP tabs know your project. Completion, hover, and signature help suggest your models, relations, and columns as you type, and you can jump to a definition, list the references to a name, apply quick fixes such as importing a class, and fold blocks out of the way.

All of this comes from [PHPantom](https://github.com/PHPantom-dev/phpantom_lsp), a language server bundled with Runlet. It needs no PHP on your Mac, and none of it runs your code: at most, it changes the tab's own text.

## Completion and Hover

Completion appears as you type, and **Edit ▸ Show Completions** (<kbd>⌥</kbd><kbd>Esc</kbd>) asks for it. Hovering over a name shows its type and documentation, and signature help shows a call's parameters while you type its arguments. Diagnostics mark problems in the code.

- **What PHPantom knows.** It indexes the tab's project, or the sandbox, without running any of it. For Docker and SSH targets, it reads the profile's local folder: the checkout on your Mac.
- **Snippet helpers.** The `Runlet\` functions and the variables your framework hands a snippet, such as `$app`, complete too. See [Snippet API](snippet-api.md#completion).
- **The status bar** shows **PHPantom** while it's ready, and **Indexing…** with a percentage while it indexes. Click it for details and **Reindex Project**: see [Keeping Up with Your Files](#keeping-up-with-your-files).
- **Turn it off** in **Settings ▸ Editor ▸ Language Service ▸ PHPantom code intelligence**.

> [!NOTE]
> External analyzers and formatters, such as PHPStan or PHP-CS-Fixer, are never started for a snippet.

## Keeping Up with Your Files

PHPantom indexes the project when you open a tab on it, then follows the files as they change on disk: when you switch Git branches, run `composer install`, or save a file in another editor. A class that appears on the new branch completes right away, without restarting anything.

- **Which files.** PHP files, `composer.json` and `composer.lock` (a change rescans `vendor/`), and `.phpantom.toml`; in Laravel projects also SQL schema dumps and `config/database.php`. Git's own files are skipped.
- **Many changes at once.** A branch switch that rewrites thousands of files reaches PHPantom in a few batches, about a third of a second after the files settle. Completion keeps working meanwhile.
- **Docker and SSH targets.** PHPantom follows the profile's local folder, the checkout on your Mac. Changes made only inside the container or on the server aren't seen.

### The Status Bar Item

| The item shows | Which means |
| --- | --- |
| **Indexing… 42%** | PHPantom is indexing the project. Hover for what it's reading, such as *Scanning vendor packages (1204/2867 files)*. Completion waits for the first index, for up to 10 seconds; after that, it may miss what isn't indexed yet. |
| **PHPantom** | Ready. |
| **PHPantom (limited)** | Ready, but part of the project can't be indexed, for example because `vendor/` isn't installed on your Mac. Hover to see why. |
| **PHPantom failed** | It couldn't start. Hover for the reason. |

Click the item for a popover with the folder PHPantom indexes, what it did last (*Parsed 60 files*), the files it follows, anything that limits it, and **Reindex Project**.

![The PHPantom popover above the status bar: ready, the sandbox's folder, the last index, the files sent to PHPantom, and Reindex Project](screenshots/navigation/phpantom-popover-light.webp#gh-light-mode-only)
![The PHPantom popover above the status bar: ready, the sandbox's folder, the last index, the files sent to PHPantom, and Reindex Project](screenshots/navigation/phpantom-popover-dark.webp#gh-dark-mode-only)

### Reindex Project

**Reindex Project** indexes the project again from scratch. It's in the popover, in **Library ▸ Reindex Project**, and in the command palette. Every tab on the same project shares one PHPantom, so they all reindex together. Nothing in the project runs or changes.

You rarely need it: use it when completion misses something that changed on disk, for example a file changed inside a container.

## Navigation Commands

| Action | How | What happens |
| --- | --- | --- |
| Go to Definition | <kbd>F12</kbd>, <kbd>⌘</kbd>-click, the context menu, or **Edit ▸ Go to Definition** | See [Where Definitions Open](#where-definitions-open). Several definitions are listed like references. |
| Find References | <kbd>⇧</kbd><kbd>F12</kbd>, the context menu, or **Edit ▸ Find References** | A popover lists each reference as `file:line` with its line of code: the tab's own first, then project files, then vendor and other files. <kbd>Return</kbd> or a click opens one, as Go to Definition would. |
| Code actions | <kbd>⌥</kbd><kbd>Return</kbd>, the light bulb in the gutter, the context menu, or **Edit ▸ Show Code Actions…** | A popover lists the fixes for the caret or selection: quick fixes first (*Import `App\Services\PriceFormatter`*, *Remove all unused imports*), then refactorings (*Inline variable*). See [Code Actions](#code-actions). |
| Inlay hints | **View ▸ Show Inlay Hints** (on by default) | Parameter names before arguments, and inferred types, as small labels in the code. See [Inlay Hints](#inlay-hints). |
| Folding | The gutter's ▾ and ▸, or **Edit ▸ Code Folding**: **Fold** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>←</kbd>), **Unfold** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>→</kbd>), **Fold All**, and **Unfold All** | A function body, array, or comment block shows as `{⋯}`, `[⋯];`, or `/*⋯*/`. See [Folding](#folding). |

These work in PHP tabs while the status bar shows PHPantom. <kbd>⌘</kbd><kbd>.</kbd> is Stop, so code actions use <kbd>⌥</kbd><kbd>Return</kbd>. Every command is in the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>), and **Settings ▸ Shortcuts** can change its shortcut.

![Find References for slug in a PHP tab: the tab's own reference first, then the project's config files and Laravel's Str.php in vendor](screenshots/navigation/find-references-light.webp#gh-light-mode-only)
![Find References for slug in a PHP tab: the tab's own reference first, then the project's config files and Laravel's Str.php in vendor](screenshots/navigation/find-references-dark.webp#gh-dark-mode-only)

## Where Definitions Open

| The definition is | It opens |
| --- | --- |
| In the tab | The caret moves there and selects the name. |
| A variable your framework provides, such as `$app` | A note names the variable and its type: there is no line to go to. |
| A project file (not under `vendor/`) | Your external editor, at its line, as file links in the output do (**Settings ▸ Editor ▸ External Editor**). With no editor set, it opens in a peek, which offers **Reveal in Finder**. |
| Under `vendor/`, outside the project, in another tab, or in Runlet's snippet API (`\Runlet\bench()`, …) | A read-only peek in Runlet: the file highlighted like the editor, scrolled to the definition's line, which is marked. **Open in** your editor and **Reveal in Finder** are there for files on disk. |
| Built into PHP (`DateTime::format`) | A note: PHPantom has no PHP source for these. |

**Docker and SSH targets.** PHPantom reads the profile's local folder, so definitions are files in that folder: project files open in your external editor, and vendor code opens in a peek from the local `vendor/`. The peek also says where the target sees the file, such as *On the container: /var/www/html/vendor/…*, or the server's path for SSH. A profile without a local folder knows only built-in PHP, so there's nothing of the project to go to.

## Code Actions

- **The tab's text only.** Runlet applies an action's changes to the tab, as one undo step named after the action (**Edit ▸ Undo Import App\Services\PriceFormatter**), and keeps the caret on the same code. An import goes to the top of a snippet, also when it has no `<?php` of its own.
- **Other files aren't changed.** An action that would change another file, or create, rename, or delete files, is listed with the reason and isn't applied.
- **Chosen late.** Some actions are worked out only when you choose them. If the code changed in the meantime, Runlet asks you to choose again.
- **The light bulb** appears in the gutter when the caret's line has a problem with a quick fix.
- **It's an edit.** An action never runs the code, except in a sandbox tab with [auto-run](sandbox-auto-run.md) on, which runs after it as after any edit.

## Inlay Hints

Inlay hints show parameter names (`cents:`) before arguments, and inferred types (`int`) before parameters. Today PHPantom infers types for arrow-function parameters, such as `fn ($p) => …` in `array_map`, but not for variables assigned from calls.

- **They aren't text.** Run, Copy, Save, Format Code, and the cursor see the code as typed.
- **They follow you.** Hints are asked for the visible lines a moment after you stop scrolling or typing; typing next to a hint removes it until the next answer.
- **View ▸ Show Inlay Hints** turns them off and on for every PHP tab, and Runlet remembers your choice.

## Folding

Function bodies, arrays, loops and other blocks, and comment blocks get a ▾ in the gutter. A folded block shows ▸, and its first line ends in a `⋯` pill.

- **Folding never changes the text.** Run, Run Selection, Copy, Save, and Format Code use all of it.
- **Getting into a fold unfolds it:** moving the caret inside with the arrow keys, a search result, or an error's line, or typing inside it. Typing above a fold moves it with its text.
- **Folds last while the tab is open.** They aren't saved.
- **Moving lines** treats a folded block as one line, and it stays folded (below).

## Moving and Duplicating Lines

**Edit ▸ Lines** has four commands, in every kind of tab (PHP, SQL, Redis, and MongoDB):

| Command | Shortcut | What happens |
| --- | --- | --- |
| Move Line Up / Down | <kbd>⌥</kbd><kbd>↑</kbd> / <kbd>⌥</kbd><kbd>↓</kbd> | The caret's line, or every line the selection touches, swaps with the line above or below. The selection stays on the moved text, so repeated presses keep moving it. At the first or last line, nothing happens. |
| Duplicate Line Up / Down | <kbd>⇧</kbd><kbd>⌥</kbd><kbd>↑</kbd> / <kbd>⇧</kbd><kbd>⌥</kbd><kbd>↓</kbd> | Copies the lines above or below themselves, as in VS Code. The selection stays on the upper copy for Up, and moves to the lower copy for Down. |

- **Undo.** Each press is one undo step, named after the command, and undoing puts the selection back. Moves don't merge: undo steps back one press at a time.
- **Folds.** A folded block moves as one line and stays folded: lines that touch it take all of it along, and lines moving past it skip it whole. Undoing such a move shows the block unfolded.
- **Text.** Indentation doesn't change, and CRLF line endings stay. A last line without a line ending swaps with the line it moves past. A selection that ends at the start of a line leaves that line out, so selecting whole lines moves just those lines.
- **The editor only.** Lines move only in the editor that has the keyboard. In a text field, the terminal, or a read-only peek, <kbd>⌥</kbd><kbd>↑</kbd> and <kbd>⌥</kbd><kbd>↓</kbd> keep their usual meaning. In the editor, they replace macOS's paragraph moves (<kbd>⌥</kbd><kbd>↑</kbd> to the start of the paragraph, <kbd>⇧</kbd><kbd>⌥</kbd><kbd>↑</kbd> to select to it).

The commands are also in the command palette, and **Settings ▸ Shortcuts** can change their keys.

## Limitations

- **Files changed outside the local folder.** PHPantom follows the files on your Mac only. **Reindex Project** picks up anything it missed.
- **Not yet supported:** rename, workspace symbols, type hierarchy, and refactorings that change several files.

## For developers

File watching, indexing progress, and Reindex Project came with [#336](https://github.com/filipac/runlet/issues/336), and Eloquent model copies that follow their files with [#340](https://github.com/filipac/runlet/issues/340): PHPantom registers its watchers with `client/registerCapability`, and Runlet watches the folder with FSEvents (`WorkspaceFileWatcher`, `FileChangeBatcher`) and follows `$/progress` (`WorkDoneProgressTracker`). `scripts/phpantom-status-screenshots.py` checks it in the app. Navigation was added under [#22](https://github.com/filipac/runlet/issues/22), moving and duplicating lines under [#234](https://github.com/filipac/runlet/issues/234), and Laravel completion was checked under [#55](https://github.com/filipac/runlet/issues/55). Rename, workspace symbols, type hierarchy, and multi-file refactorings are deferred under #22.

- **Hidden lines.** The tab's code is sent to PHPantom with lines Runlet adds: a `<?php` for snippets without one, and `@var` lines for the variables a project driver provides (`ScratchDocumentMapping`). Snippets without `<?php` map through that line; a definition on a driver's `@var` line gets the note; a result on a hidden line has nowhere to go and is left out of reference lists; code actions that would replace hidden text are refused; and nothing moves into or out of them when moving lines, so the editor's first line stays first.
- **Code actions.** Actions with only `data` are resolved when chosen (`codeAction/resolve`). Runlet declares `workspace.applyEdit: false` and `workspaceEdit.documentChanges: false`.
- **Inlay hints.** Kinds 1 (types) and 2 (parameters) are drawn for the visible lines plus 20, debounced; PHPantom's kindless "N references" hints are left out. The setting is `inlayHints` in `settings.json`.
- **Built-in definitions.** PHPantom 0.10.0 returns `null` for built-in functions and classes, and `phpantom-stub://<Class>` for a built-in class's member.
- **Lines.** The commands are `LineCommand` (`Runlet/Editor/EditorLineMoves.swift`); the text transform is `LineMove` (RunletCore).
- What PHPantom 0.10.0 returns for each request, what Runlet does with it, and the tests (`NavigationTests`, `NavigationIntegrationTests`, `FramePeekTests`) are in [compatibility.md ▸ Navigation](compatibility.md#navigation-22-phpantom-0100), with the prototype gate and Laravel completion results. Screenshots are in [PR #223](https://github.com/filipac/runlet/pull/223) (`scripts/navigation-screenshots.py`).
- Settings ▸ Editor ▸ Language Service turns PHPantom off; Runlet's PHPantom configuration disables PHPStan, PHPCS, Mago, and workspace diagnostics.
