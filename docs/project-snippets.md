# Project snippets

Project snippets are PHP (or [SQL](#sql-snippets)) files that live in a project, so a team
can share them through git. Runlet shows them in the Snippets panel next to your personal snippets. Loading,
opening, or copying a project snippet never runs it.

## Where Runlet looks

Runlet reads `<project root>/.runlet/snippets/*.php` and `*.sql`. The project root depends
on the active tab's target:

| Target | Project root |
| --- | --- |
| Local project | The project's directory |
| Docker profile | The profile's **Local source** checkout (Docker profile editor ▸ Code Intelligence). Without one, the profile has no project snippets. |
| SSH profile | The profile's **Local folder** checkout, including profiles with a remote container step. Without one, it has no project snippets. |
| Laravel sandbox | None |

Only files directly in `snippets/` count. Hidden files, nested folders, files that are not
UTF-8, files that cannot be read, and files over 1 MiB are skipped. Snippets are sorted by
label.

The `.runlet/` folder also holds [project drivers](drivers.md). Drivers are
`.runlet/*Driver.php` files directly in `.runlet/`; the runner never looks inside
`.runlet/snippets/`, so a snippet is never loaded as a driver and never runs on its own.

## File format

```php
<?php
/**
 * @label Recent users
 * @description The ten newest accounts,
 *   newest first
 */

User::latest()->take(10)->get();
```

- **Metadata.** The first docblock is metadata if it comes before any code (whitespace and
  other comments may precede it) and contains `@label`, `@description`, or `@input`. `@label`
  and `@description` can continue on the following lines. Other tags are ignored. A docblock
  without these tags is part of the code.
- **Inputs.** `@input` lines make a parameterised snippet: opening it asks for the values and
  puts them at the top of the code as PHP literals, without running it. See
  [parameterised snippets](snippet-inputs.md).
- **Label.** `@label`, or the file name without `.php`.
- **Code.** The file without its opening `<?php` tag and without the metadata docblock,
  with leading blank lines and trailing whitespace removed. This is what Runlet shows and
  loads into the editor.

The format matches Tinkerwell's `.tinkerwell/snippets`, so those files can be moved to
`.runlet/snippets/` as they are.

## SQL snippets

`.sql` files are SQL snippets ([#130](https://github.com/filipac/runlet/issues/130)). They are
listed with the PHP ones (with an **SQL** badge) and open as [SQL tabs](sql-tabs.md); opening
never runs them.

```sql
-- @label Pending orders
-- @description Orders waiting for payment,
--   oldest first

SELECT id, customer_id, total, placed_at
FROM orders
WHERE status = 'pending'
ORDER BY placed_at;
```

- **Metadata.** The first run of `--` comment lines before any statement, when it has `@label`
  or `@description` (a blank line ends the run), or a `/** … */` docblock as in PHP files. It is
  left out of the code. Comments without these tags stay in the code.
- **Label.** `@label`, or the file name without `.sql`.
- **No inputs.** `@input` lines mean nothing in SQL snippets.
- **Connection.** An optional `@connection` line; see [Connections](#connections).
- **Saving.** Save Snippet to Project… from an SQL tab writes `<slug>.sql` with `-- @label` and
  `-- @description` lines, and an `-- @connection` line for the tab's connection unless you turn
  that off in the sheet.

### Connections

An SQL snippet can name the connection it opens on ([#149](https://github.com/filipac/runlet/issues/149)):

```sql
-- @label Monthly revenue
-- @connection reporting

SELECT strftime('%Y-%m', placed_at) AS month, sum(total) AS revenue
FROM orders
GROUP BY month;
```

- **`-- @connection <name>`**: a [saved connection](sql-tabs.md#saved-connections) with that
  name if the tab's target has one (its own first, then one of all targets; names ignore case),
  else the application's connection with that name (a key of Laravel's `database.connections`,
  a Doctrine connection). It is one line; spaces in the name are kept.
- **`-- @connection <name> (saved)`**: only a saved connection. When the target has none with
  that name, the tab uses the default connection and the SQL bar says the connection from this
  snippet no longer exists.
- Only names are written, never a host, user, database, or password, so the file can be
  committed and works for everyone who has a connection with that name.
- The line may also be in a `/** … */` docblock (` * @connection reporting`). On its own, without
  `@label` or `@description`, it still counts as metadata. PHP snippets ignore it.
- Saving from an SQL tab writes `-- @connection reporting` for an application connection and
  `-- @connection Reporting (saved)` for a saved one; nothing for the default connection.

The panel shows the connection as a badge, the search matches it, and Copy to Personal Snippets
keeps it. Opening never runs anything; see [which connection opens](sql-tabs.md#which-connection-opens).

## In the Snippets panel

When the active tab's target has a project root, the Snippets panel (⇧⌘L) shows a
**Project snippets — <name>** section above your personal snippets. Rows are read-only:
edit the file to change a snippet. The search field filters both sections.

| Action | What it does |
| --- | --- |
| Open in Current Tab | Replaces the tab's code. The tab keeps its target. |
| Open in New Tab (or double-click) | Opens the code in a new tab with the same target. |
| Copy Code | Copies the code. |
| Copy to Personal Snippets | Saves an editable personal copy, including its description and `@input` lines, associated with the target. |
| Reveal in Finder | Shows the file. |
| Save as Artisan Command… / Save as Test… | Writes the snippet into the project as a command class or a Pest or PHPUnit test, through a save panel, without running it ([promote a snippet](promote-snippets.md), [#39](https://github.com/filipac/runlet/issues/39)). |

A snippet with `@input` lines shows an "inputs" badge, and opening it (any of the Open
actions, ⇧↩ Insert, or Open Anything) first shows the [input form](snippet-inputs.md#opening-one).

Runlet reads the folder when the panel appears and when you press the reload button in the
section header. Changes made on disk while the panel is open appear after a reload. Automatic folder-change reloading is tracked in [#51](https://github.com/filipac/runlet/issues/51).

## Saving a project snippet

Save Snippet (⌥⌘S) offers **Save to: Personal / Project (.runlet/snippets)** when the
tab's target has a project root. Choosing Project asks for a label and an optional
description and writes `.runlet/snippets/<slug>.php`, where the slug is the label in
lowercase ASCII letters and digits joined by `-` (for example `recent-users.php`). If that
file already exists, Runlet asks before replacing it. Saving only writes the file; commit it
to share it.

Personal snippets also support optional descriptions when saving or editing; see [personal snippet descriptions](personal-snippets.md).
