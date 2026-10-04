# Code navigation in PHP tabs

Go to Definition, Find References, code actions, inlay hints, and folding come from
[PHPantom](https://github.com/PHPantom-dev/phpantom_lsp), the language server that already gives
PHP tabs their completion, hover, signature help, and diagnostics
([#22](https://github.com/filipac/runlet/issues/22)). They work in PHP tabs while the status bar
shows PHPantom. None of them runs code: they ask the language server and change, at most, the
tab's own text.

| Action | How | What happens |
| --- | --- | --- |
| Go to Definition | F12, ⌘-click, the context menu, Edit ▸ Go to Definition | See [where definitions open](#where-definitions-open). Several definitions are listed like references. |
| Find References | ⇧F12, the context menu, Edit ▸ Find References | A popover lists each reference as file:line with its line of code (the name in bold): the tab's own first, then project files, then vendor and other files. Return or a click opens one the way Go to Definition would. |
| Code actions | ⌥↩, the light bulb in the gutter, the context menu, Edit ▸ Show Code Actions… | A popover lists what PHPantom offers at the caret or selection: quick fixes first (Import `App\Services\PriceFormatter`, Remove all unused imports), then refactorings (Inline variable). See [code actions](#code-actions). |
| Inlay hints | View ▸ Show Inlay Hints (on by default; saved) | Parameter names before arguments and inferred types, as small labels in the code. See [inlay hints](#inlay-hints). |
| Folding | The gutter's ▾ and ▸, Edit ▸ Code Folding ▸ Fold (⌥⌘←), Unfold (⌥⌘→), Fold All, Unfold All | A function body, array, or comment block shows as `{⋯}`, `[⋯];`, or `/*⋯*/`. See [folding](#folding). |

⌘. is Stop, so code actions use ⌥↩. Every shortcut can be changed in Settings ▸ Shortcuts, and
the commands are in the command palette (⇧⌘P).

## Where definitions open

| The definition is | It opens |
| --- | --- |
| In the tab | The caret moves there and the name is selected. Snippets without `<?php` map through the line Runlet adds before them. |
| A variable a project driver provides (`$app`, from the hidden `@var` lines) | A note names the variable and its type: there is no line to go to. |
| A project file (not under `vendor/`) | The external editor (Settings ▸ Editor) at its line, as file links in the output do. With no external editor set, it opens in a peek, which offers Reveal in Finder. |
| Under `vendor/`, outside the project, another tab's code, or Runlet's snippet API (`\Runlet\bench()`, …) | A read-only peek in Runlet: the file highlighted like the editor, scrolled to the definition's line, which is marked. Open in *editor* and Reveal in Finder are there for files on disk. |
| Built into PHP (`DateTime::format`) | A note: PHPantom 0.10 has no PHP source for these. |

**Docker and SSH targets.** PHPantom reads the profile's local folder (its checkout on this
Mac), so definitions are files in that folder: project files open in the external editor, and
vendor code is peeked from the local `vendor/`. The peek also says where the target sees the
file (*On the container: /var/www/html/vendor/…*, or the server's path for SSH), through the same
path mapping as the output's file links. A profile without a local folder has only built-in PHP,
so there is nothing of the project to go to.

## Code actions

- Runlet applies an action's changes to the **tab's own text only**, as one undo step named after
  the action (Edit ▸ Undo Import App\Services\PriceFormatter), and keeps the caret on the same code. An import added after
  `<?php` goes to the top of a snippet that has no `<?php` of its own.
- An action that would change another file, create, rename, or delete files, or replace the lines
  Runlet adds before a snippet is listed with the reason and isn't applied. Multi-file
  refactorings, rename, workspace symbols, and type hierarchy are deferred.
- Some actions are computed only when chosen (`codeAction/resolve`); if the code changed in the
  meantime, Runlet asks you to choose again.
- The light bulb appears in the gutter when the caret's line has a diagnostic with a quick fix.
- An action is an edit like typing: it never runs the code (a sandbox tab with auto-run on runs
  after it as after any edit).

## Inlay hints

- Parameter names (`cents:`) appear before arguments, and inferred types (`int`) before
  parameters PHPantom infers. With PHPantom 0.10.0, types are shown for arrow-function parameters
  (`fn ($p) => …` in `array_map`); variables assigned from calls get none. PHPantom's "N
  references" hints after declarations are left out.
- The hints are not text: Run, Copy, Save, Format Code, and the cursor see the code as typed.
  They are asked for the visible lines a moment after scrolling or typing stops; typing next to
  a hint removes it until the next answer.
- View ▸ Show Inlay Hints turns them off and on for every PHP tab; the choice is saved with the
  settings (`inlayHints`).

## Folding

- Foldable blocks come from PHPantom (function bodies, arrays, loops and other blocks, comment blocks) and
  get a ▾ in the gutter; a folded one shows ▸ and the block's first line ends in a `⋯` pill.
- Folding never changes the text: Run, Run Selection, Copy, Save, and Format Code use all of it.
  Moving the caret into a folded block (arrow keys, Go to Line, a search result, an error line)
  or typing inside it unfolds it. Typing above a fold moves it with its text.
- Folds last while the tab is open; they aren't saved.

## Limitations

- The tab's code is sent to PHPantom with its hidden lines (`ScratchDocumentMapping`), so a
  result on those lines has nowhere to go and is left out of reference lists.
- References and definitions in other files come from PHPantom's index of the project as it was
  when the language server started; Restart Language Server picks up files changed on disk.
- Deferred ([#22](https://github.com/filipac/runlet/issues/22)): rename, workspace symbols, type
  hierarchy, and refactorings that change several files.
