# Running Code

Press <kbd>⌘</kbd><kbd>R</kbd> to run the current tab. Runlet runs your snippet on the tab's target, in a fresh PHP process with your application booted, and shows what happened in the output pane next to the editor. Every run is kept in History, so you can open it again later.

Nothing runs by itself. Opening a project, a file, a snippet, or a History entry, switching tabs, and restoring your session after a relaunch never run code: it runs when you press Run.

## Running a Snippet

| Action | How | What runs |
| --- | --- | --- |
| Run | <kbd>⌘</kbd><kbd>R</kbd>, **Run ▸ Run**, or **Run** in the toolbar | The whole tab. |
| Run Selection | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd>, **Run ▸ Run Selection**, or **Run Selection** in the toolbar | Only the selected code. Errors, dumps, and [magic comments](magic-comments.md) point at the lines you see in the editor. |
| Stop | <kbd>⌘</kbd><kbd>.</kbd>, **Run ▸ Stop**, or **Stop** in the toolbar while the tab runs | Ends the run. Whatever arrived before Stop stays in the output. |
| Profile Run | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd>, **Run ▸ Profile Run** | The whole tab, sampled every millisecond, with a flame graph in the output. It needs the Excimer extension in the target's PHP; Runlet's own PHP includes it. |

The last expression is the result, as in Tinker, so you don't need `return` or a final semicolon:

```php
use App\Models\Order;

Order::where('status', 'pending')->latest()->take(10)->get()
```

[Snippet API](snippet-api.md) lists everything a snippet can use, and what each kind of output looks like.

> [!TIP]
> Turn on **Settings ▸ General ▸ Running ▸ Run prefers selection** and <kbd>⌘</kbd><kbd>R</kbd> runs only the selection when there is one. <kbd>⇧</kbd><kbd>⌘</kbd><kbd>R</kbd> always works.

### Before a Run

A few settings change what a run does. They apply to Run, Run Selection, and Profile Run alike:

- **Production asks first.** On a target marked as production, Runlet shows what will run and where before it runs: <kbd>⌘</kbd><kbd>Return</kbd> runs it, and <kbd>Return</kbd> or <kbd>Esc</kbd> cancels. See [Production hosts](ssh.md#production-hosts).
- **[Dry Run](dry-run.md)** (**Run ▸ Dry Run (Roll Back Database Changes)**, or the toolbar button) makes the tab's runs roll back their database changes.
- **Run ▸ Toggle Strict Types** and **Run ▸ Toggle Mail Interception** turn the defaults from **Settings ▸ General** on or off. Projects and profiles can override them.
- **Format before run** (**Settings ▸ Editor ▸ Formatting**) formats a PHP tab before Run and Profile Run. See [Format Code](format-code.md).

In the Laravel sandbox, you can also turn on [auto-run](sandbox-auto-run.md) for a tab, so it runs a moment after you stop typing.

## The Output Pane

The output pane shows the run as it goes: printed output, `dump()` calls, the result, errors with their line, and Runlet's notices. The status bar shows the run's state and its elapsed time, and a run ends as completed, failed, or stopped.

<!-- screenshot: the output pane after a run in the sandbox, with a dump card, a Result card showing a collection as a table, and the run's footer -->

Values open as expandable trees, and rows and collections as tables. A value card can switch views: **Tree**, **Table**, and, for strings, the [string viewers](string-viewers.md) (**JSON**, **Text**, **Image**, and **Preview**). The **Expand values** menu in the pane's header decides how far values open on their own: **Collapsed**, **First level** (the default), or **Expand all**.

Above the output, the run inspector adds a section for each kind of record, with its count: **Queries** for the SQL your code ran, **Mail** for the mail it sent, **Log** for what it [logged](logs.md), and sections your project's driver adds. **Run ▸ Show Queries** and **Run ▸ Show Mail** jump to them. The footer has the run's [timings](run-timings.md).

### Display Modes

| Mode | Shortcut | Shows |
| --- | --- | --- |
| **Structured** | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>1</kbd> | Cards you can expand, with tables, previews, and links to lines. The default. |
| **Plain** | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>2</kbd> | A transcript, as a command-line run would print it. |
| **Raw** | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>3</kbd> | Exactly what PHP wrote to standard output and standard error. |

Switch with the picker in the pane's header, the shortcuts, or the **Run** menu. The mode applies to every tab.

### Realtime or At Once

**Settings ▸ General ▸ Output ▸ Show a run's output** decides when output appears:

- **Realtime** (the default) shows printed output, dumps, magic-comment values, and the inspector's queries, mail, and logs as the code runs. That helps with long loops and slow queries.
- **At once** shows everything together when the run ends: completed, failed, `dd()`, `exit`, or stopped. While it runs, the status bar shows the time and Stop still works.

Both work the same on every target. AI clients always get the whole result.

### Copying and Saving

| To | Do |
| --- | --- |
| Copy the whole output as text | **Copy Output** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd>), or the copy button in the pane's header |
| Copy it as Markdown | **Copy Output as Markdown**, in the copy button's menu or the **Run** menu |
| Save it to a file | **Save Output As…** |
| Copy one value | The value card's copy menu: **Copy as JSON**, **Copy as PHP**, or **Copy as Markdown** |
| Copy or export a table | **Copy CSV** and **Export CSV…** above the table (the rows shown), or **Open in Window** for a larger view with search and sorting |
| Clear the output | **Clear Output** (<kbd>⌘</kbd><kbd>K</kbd>) |

File paths in dumps, errors, and stack traces open at their line in your editor. Choose it in **Settings ▸ Editor ▸ External Editor**.

### Showing and Hiding the Pane

- **Show/Hide Output Pane** (<kbd>⌃</kbd><kbd>⌘</kbd><kbd>O</kbd>, in the **View** menu) shows or hides it.
- **Move Output Right/Below** (<kbd>⌃</kbd><kbd>.</kbd>) moves it beside or under the editor. **Settings ▸ General ▸ Appearance ▸ Output pane** sets the default. Drag the divider to resize it.
- **Hide the output pane until a run** (**Settings ▸ General ▸ Output**, off by default) gives the editor the whole window until you run the tab. The pane then opens where it was, at its last size. Tabs that haven't run, or whose output you cleared, hide it again.
- **Escape hides the output pane** (**Settings ▸ General ▸ Output**, off by default) lets <kbd>Esc</kbd> in the editor hide the tab's pane until its next run. Completions and value panels still close first, <kbd>Esc</kbd> leaves the pane alone while the find bar is open, and <kbd>⌘</kbd><kbd>.</kbd> still stops a run.

### Large Output

The output pane stays responsive with large runs:

- **Structured** shows a run's last 1,000 cards, with **Show All** to see every card, and the last 5,000 lines of printed output.
- **Plain**, **Raw**, **Copy Output**, and **Save Output As…** always have everything, up to 8 MiB of output per run.
- Values are bounded in depth and size; [Snippet API](snippet-api.md#output) has the limits.

## Run History

History keeps every run's code, target, time, and final status. Open it with **Library ▸ Show History** (<kbd>⌘</kbd><kbd>Y</kbd>), in the library panel next to the editor; **Show/Hide History & Snippets** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>L</kbd>) shows or hides that panel.

<!-- screenshot: the History pane with This Project selected, a few entries with status icons, one with a PROD badge, and the Load in Current Tab and Open in New Tab buttons -->

- **This Project or All Projects.** History starts with the runs on the current tab's target. **All Projects** shows every run, and its search also matches target names.
- **Search** matches the code. For SQL tabs, a **Connection** menu shows the runs on one connection.
- **Each entry** shows its status, its target, when it ran, and its first lines. A run on a production target keeps a **PROD** badge (**STAGING** for staging), even after you change the target's marking. Searching for `production` finds those runs.
- **Running the same code again** moves its entry to the top.

Opening an entry never runs it:

| To | Do |
| --- | --- |
| Open an entry | <kbd>Return</kbd> or double-click. By default, it opens in the current tab when that tab is empty and on the same target, and in a new tab otherwise; change this in **Settings ▸ General ▸ History & Snippets ▸ Double-click opens in**. |
| Open it in a new tab | <kbd>⌘</kbd><kbd>Return</kbd>, or **Open in New Tab** |
| Replace the current tab's code | **Load in Current Tab** (<kbd>⌘</kbd><kbd>Z</kbd> undoes it) |
| Insert its code at the cursor | <kbd>⇧</kbd><kbd>Return</kbd> |
| Keep it | **Save as Snippet** in its context menu. See [Personal Snippets](personal-snippets.md). |
| Remove it | **Delete** in its context menu, or <kbd>⌫</kbd> |

You can also type `!` in Open Anything (<kbd>⌘</kbd><kbd>P</kbd>) to search History.

History keeps the most recent 1,000 runs; change that (50 to 10,000) in **Settings ▸ General ▸ History & Snippets ▸ Keep the most recent**. **Clear History…** in the pane's footer or in that section removes every entry, and can't be undone. Snippets aren't affected.

## For developers

- Output delivery, Realtime or At once, is [#82](https://github.com/filipac/runlet/issues/82); hiding the output pane until a run, and Escape hiding it, are [#60](https://github.com/filipac/runlet/issues/60); the PROD badge in History is [#12](https://github.com/filipac/runlet/issues/12); the History connection filter is [#149](https://github.com/filipac/runlet/issues/149); Profile Run is [#41](https://github.com/filipac/runlet/issues/41).
- Settings: `outputMode` (`structured`), `valueExpansion` (`firstLevel`), `outputDelivery` (`realtime`), `outputLayout` (`right`), `runPrefersSelection`, `hideOutputUntilRun`, `escapeHidesOutput`, `libraryOpenBehavior` (`reuseBlankTab`), and `historyLimit` (1,000; 50–10,000) in `AppSettings` (`Models.swift`, RunletCore). A saved *Show values while the code runs* turned off (from before #82) reads as At once.
- Applying events and the gate that holds them for At once: `RunEventGate` in `OutputDelivery.swift`; [Architecture ▸ Applying events](architecture.md#applying-events-82). The tab updates at most ten times a second, less often while drawing is slow.
- The visibility rules for the pane: `OutputPaneVisibility`, tested in `OutputPaneVisibilityTests`. The pane's state is per tab and never saved. Escape was checked with the Debug step `editor-key:escape`.
- The pane: `OutputPane.swift`; the History and Snippets panes: `LibraryInspector.swift`; the commands and their default shortcuts: `CommandCatalog` in `Runlet/App/Commands.swift`.
- Evidence for both output settings, including what was verified end to end and what only by unit tests: [compatibility.md ▸ Output: realtime or at once](compatibility.md#output-realtime-or-at-once-82) and [Output pane: hide until a run, Escape hides it](compatibility.md#output-pane-hide-until-a-run-escape-hides-it-60).
