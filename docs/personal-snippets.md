# Personal Snippets

Save the code you reuse as a snippet, and open it again in any tab with a few keys. Personal snippets live in Runlet on your Mac. To share snippets with your team through git, save them as [project snippets](project-snippets.md) instead.

Saving, editing, and opening a snippet never runs it. It runs when you press Run, with the usual confirmation on production targets.

## Saving a Snippet

Choose **Library ▸ Save as Snippet…** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd>), or the save button at the top of the Snippets panel. With a selection, the snippet is the selected code; otherwise it's the whole tab.

The sheet asks for:

- **Label:** the snippet's name in the list.
- **Description (optional):** a line or two about what it does. Runlet trims it, and an empty description is left out.
- **Associate with** the tab's target: an associated snippet opens in a new tab on that target, and the list always shows the association. Leave it off for a snippet that works with any target.

When the tab's target has a project folder, the sheet also has **Save to: Personal / Project (.runlet/snippets)**. See [Saving a Project Snippet](project-snippets.md#saving-a-project-snippet).

You can also keep a run from History: **Save as Snippet** in its context menu saves its code with its target.

## Finding and Opening Snippets

**Library ▸ Show Snippets** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>L</kbd>) opens the Snippets panel next to the editor, with the current project's [project snippets](project-snippets.md) above your personal ones. The search field matches labels, descriptions, and code. Descriptions show below the labels, in two lines at most; hover for the whole text.

![Personal snippets with descriptions in the Snippets panel](screenshots/personal-snippet-descriptions-light.png)

| To | Do |
| --- | --- |
| Open a snippet | <kbd>Return</kbd> or double-click. By default, it opens in the current tab when that tab is empty and on the same target, and in a new tab otherwise; change this in **Settings ▸ General ▸ History & Snippets ▸ Double-click opens in**. |
| Replace the current tab's code | **Open in Current Tab**. The tab keeps its target. |
| Open it in a new tab | <kbd>⌘</kbd><kbd>Return</kbd>, or **Open in New Tab**. The new tab uses the snippet's target. |
| Insert it at the cursor | <kbd>⇧</kbd><kbd>Return</kbd> |
| Find it from anywhere | Type `#` in Open Anything (<kbd>⌘</kbd><kbd>P</kbd>), then part of its label, description, or code. |

## Editing Snippets

Select a personal snippet and choose **Edit…** in its context menu to change its label, description, target (**Any target** or one of yours), and code. An SQL, Redis, or MongoDB snippet also has its **Connection**.

![Editing a personal snippet's description](screenshots/personal-snippet-descriptions-edit-dark.png)

The context menu also has:

- **Duplicate:** a copy, with the same description.
- **Copy Code:** the code, to the clipboard.
- **Save as Artisan Command…** and **Save as Test…:** write the snippet into its project as a command class or a test for you to review. See [Promote a Snippet](promote-snippets.md).
- **Delete:** removes the snippet after asking. It can't be undone.

## Snippets With Inputs

A snippet that starts with a docblock of `@input` lines asks for those values when it opens, and puts them at the top of the code:

```php
/**
 * @input int $userId "User ID"
 */

App\Models\User::findOrFail($userId)->subscriptions
```

See [Snippet Inputs](snippet-inputs.md).

## SQL, Redis, and MongoDB Snippets

Snippets work in every kind of tab. Saving from an [SQL tab](sql-tabs.md), a [Redis tab](redis.md), or a [MongoDB tab](mongodb.md) makes a snippet in that language:

- **A badge** in the list: **SQL**, **REDIS**, or **MONGODB**. Open Anything names the language too, and typing it finds them.
- **It opens as that kind of tab.** Opening one into the current tab switches the tab's language.
- **Its connection.** The save sheet keeps the tab's connection (**Open on …**), unless you turn that off. The snippet then opens on that connection when the tab's target has it, and otherwise on the default connection, with a note. **Edit…** changes or removes it.
- **Inputs.** SQL snippets have none. Redis snippets take `# @input` lines that fill `$name` arguments as quoted Redis arguments, and the tab opens with the commands only. MongoDB snippets take `// @input` lines that fill `{"$input": "name"}` placeholders with JSON values. See [Redis snippets](project-snippets.md#redis-snippets) and [MongoDB snippets](project-snippets.md#mongodb-snippets).

**Duplicate**, **Copy to Personal Snippets**, and History's **Save as Snippet** keep a snippet's language and connection.

## AI Clients

[AI clients](mcp.md) connected to Runlet can list, read, and save your personal snippets, with their descriptions. They can't run a snippet by itself: running code always goes through your approval.

## For developers

Descriptions were added under [#52](https://github.com/filipac/runlet/issues/52), snippet inputs under [#14](https://github.com/filipac/runlet/issues/14), and promotion under [#39](https://github.com/filipac/runlet/issues/39). SQL snippets are [#130](https://github.com/filipac/runlet/issues/130), with their connection in [#149](https://github.com/filipac/runlet/issues/149); Redis snippets are [#190](https://github.com/filipac/runlet/issues/190) and their inputs [#205](https://github.com/filipac/runlet/issues/205); MongoDB snippets are [#207](https://github.com/filipac/runlet/issues/207).

**Storage.** Personal snippets are in `State/snippets.json` in Runlet's data folder.

- `description` is optional. Version-1 libraries without the field stay readable, with no migration or schema change. Persistence checks cover old libraries, a mixed old and new library after saving and reloading, Unicode descriptions, clearing, and explicit `null` descriptions.
- `language` is `"sql"`, `"redis"`, or `"mongodb"`. PHP snippets don't write the key, so libraries saved before snippets had a language load unchanged, as PHP.
- `connection` is `{"kind": "application" | "saved", "name": "…"}`: a name, never a connection's definition. Libraries without the key load unchanged.

**MCP.** `list_snippets` and `get_snippet` return `description` when present (and `list_snippets` searches it), `language` (the snippet's language, such as `php`, `sql`, or `redis`), and for SQL snippets the connection's name as `connection`. A Redis snippet's typed passwords show as `•••`. `add_snippet` keeps its arguments, saves without a description, and takes an optional `language` (`php` or `sql`). Copy to Personal Snippets keeps a `.redis` file's `# @input` lines; the panel's preview shows the commands without them.

**Validation** (descriptions, #52):

- 38 focused package tests passed (`PersistenceTests`, `ProjectSnippetsTests`, and MCP approval, catalog, and report checks).
- 6 native library UI tests passed, including the keyboard, history, palette, and file-reload checks. They cover saving, searching, editing, restarting, opening through the palette, clearing, and keeping project descriptions when copying and duplicating, with scratch data; the save, edit, and open test checks that code with a file-writing side effect never runs.
- 34 MCP end-to-end checks passed through the bundled CLI and the native Debug app, including description-only search, description reads, and legacy entries without the field, plus the existing approval and cancellation flows, with scratch data, a local fixture, and sandbox runs. Docker and real SSH runs weren't exercised for this change.
- To reproduce the screenshots: `python3 scripts/snippet-description-screenshots.py /path/to/Runlet.app /path/to/output` against a Debug build. It seeds a temporary snippet library and uses `RUNLET_DEBUG_STEPS` and `RUNLET_SNAPSHOT_DIR`; no code runs.
