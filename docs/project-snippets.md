# Project snippets

Project snippets are PHP files that live in a project, so a team can share them through
git. Runlet shows them in the Snippets panel next to your personal snippets. Loading,
opening, or copying a project snippet never runs it.

## Where Runlet looks

Runlet reads `<project root>/.runlet/snippets/*.php`. The project root depends on the
active tab's target:

| Target | Project root |
| --- | --- |
| Local project | The project's directory |
| Docker profile | The profile's **Local source** checkout (Docker profile editor ▸ Code Intelligence). Without one, the profile has no project snippets. |
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
  other comments may precede it) and contains `@label` or `@description`. Either tag can
  continue on the following lines. Other tags are ignored. A docblock without these tags is
  part of the code.
- **Label.** `@label`, or the file name without `.php`.
- **Code.** The file without its opening `<?php` tag and without the metadata docblock,
  with leading blank lines and trailing whitespace removed. This is what Runlet shows and
  loads into the editor.

The format matches Tinkerwell's `.tinkerwell/snippets`, so those files can be moved to
`.runlet/snippets/` as they are.

## In the Snippets panel

When the active tab's target has a project root, the Snippets panel (⇧⌘L) shows a
**Project snippets — <name>** section above your personal snippets. Rows are read-only:
edit the file to change a snippet. The search field filters both sections.

| Action | What it does |
| --- | --- |
| Open in Current Tab | Replaces the tab's code. The tab keeps its target. |
| Open in New Tab (or double-click) | Opens the code in a new tab with the same target. |
| Copy Code | Copies the code. |
| Copy to Personal Snippets | Saves an editable personal copy, associated with the target. |
| Reveal in Finder | Shows the file. |

Runlet reads the folder when the panel appears and when you press the reload button in the
section header. Changes made on disk while the panel is open appear after a reload.

## Saving a project snippet

Save Snippet (⌥⌘S) offers **Save to: Personal / Project (.runlet/snippets)** when the
tab's target has a project root. Choosing Project asks for a label and an optional
description and writes `.runlet/snippets/<slug>.php`, where the slug is the label in
lowercase ASCII letters and digits joined by `-` (for example `recent-users.php`). If that
file already exists, Runlet asks before replacing it. Saving only writes the file; commit it
to share it.
