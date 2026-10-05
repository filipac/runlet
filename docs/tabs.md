# Tabs

Every window has tabs, and each tab is a PHP, SQL ([SQL tabs](sql-tabs.md)), Redis
([Redis](redis.md)), or MongoDB ([MongoDB](mongodb.md)) tab with its own target and code. Tabs
are saved with the session and restored after a relaunch; restoring a tab never runs its code.
Pinned tabs were added under [#279](https://github.com/filipac/runlet/issues/279), and the
rename field under [#285](https://github.com/filipac/runlet/issues/285).

## Two layouts

- **Horizontal:** a tab bar above the editor. Each tab shows its target's icon, its title, a
  badge for SQL, Redis, and MongoDB tabs, PRODUCTION for a production target, a spinner while
  it runs, and a close button.
- **Vertical:** a sidebar of tab cards with the target, its runtime and PHP version, and the
  framework or `.runlet` driver from the last run. Drag a card to reorder the tabs, and drag the
  sidebar's edge to resize it.

Switch with **View ▸ Toggle Vertical Tabs** (⌃⌘T), the toolbar button, or **Settings ▸ General ▸
Tabs**. The layout applies to every window.

## Working with tabs

| Action | How |
| --- | --- |
| New tab | **File ▸ New Tab** (⌘T), or **+** in the tab bar or the sidebar. File also has New SQL, Redis, and MongoDB Tab. |
| Rename | Double-click the tab, **Rename…** in its context menu, or **Window ▸ Rename Tab…** (see [Renaming a tab](#renaming-a-tab)) |
| Duplicate | **Duplicate** in its context menu, or **File ▸ Duplicate Tab** (⇧⌘D) |
| Close | The close button, **Close** in its context menu, or **File ▸ Close Tab** (⌘W; a pinned tab asks first) |
| Close the others | **Close Other Tabs** in its context menu, or **Window ▸ Close Other Tabs** |
| Close to the right | **Window ▸ Close Tabs to the Right** |
| Reopen a closed tab | **Window ▸ Reopen Closed Tab** (⇧⌘T): the last 20 closed tabs that had code |
| Select | Click it, ⇧⌘] and ⇧⌘[ for the next and previous tab, ⌘1…⌘8 for the nth tab, ⌘9 for the last |
| Pin or unpin | **Pin Tab** / **Unpin Tab** in its context menu, or **Window ▸ Pin Tab** (see [Pinned tabs](#pinned-tabs)) |

The tab bar and the vertical tabs share one context menu: Rename…, Duplicate, Pin Tab (or
Unpin Tab), Switch to … for every other tab language, Close, and Close Other Tabs. Every Window
menu command is also in the command palette (⇧⌘P), where Settings ▸ Shortcuts can give it a
shortcut.

## Renaming a tab

Renaming works the same in the tab bar, the vertical tabs, and pinned tabs in both layouts.

- **Start:** double-click the tab, choose **Rename…** in its context menu, or **Window ▸ Rename
  Tab…** for the selected tab. The command palette (⇧⌘P) has Rename Tab…, and Open Anything (⌘P)
  lists it when you type "rename".
- **The title is selected:** the title turns into a field that has the keyboard with the whole
  title selected, so typing replaces it. Click in the field to place the caret or select a word;
  the click doesn't select the tab or start a drag.
- **Finish:**
  - **Return** renames the tab (Tab does too).
  - **Esc** keeps the old title, and does nothing else: it doesn't hide the output pane.
  - **A click elsewhere** renames it, as in Finder: in the editor, on another tab, or on an empty
    part of the tab bar.
  - An empty or whitespace-only name keeps the old title, and the name is trimmed.
- **While renaming:** keys go to the field, never to the editor, and ⌘W closes nothing. After
  Return or Esc the editor has the keyboard again (or whatever had it before).
- **From the palettes:** the field takes the keyboard once the palette has closed and given its
  window the keyboard back, and takes it back if something grabs it within the first second.

## Pinned tabs

Pin the tabs you keep open all the time, such as a scratch snippet, a production SQL tab, or a
Redis tab. Any tab kind can be pinned, in both layouts.

- **Pin and unpin:** **Pin Tab** or **Unpin Tab** in the tab's context menu, or **Window ▸ Pin
  Tab** for the selected tab (checked while it is pinned). The command palette (⇧⌘P) has Pin Tab,
  and Open Anything (⌘P) lists it when you type "pin" or "unpin". Pinning runs nothing.
- **Where they go:** pinned tabs come first: leftmost in the tab bar, at the top of the vertical
  tabs.
  - Pinning moves a tab to the end of the pinned tabs; unpinning moves it to the start of the
    other tabs.
  - New tabs open after the pinned ones, even when a pinned tab is selected.
  - A dragged tab stays in its group: in the vertical tabs, pinned and other tabs are separate
    sections, and a tab dropped past its group's end stays at that end.
  - ⌘1…⌘9 count the tabs as shown, pinned tabs first.
- **In the tab bar:** a pinned tab is compact: the tab kind's icon in its colour (PHP, SQL,
  Redis, MongoDB), a short title, and no close button. A spinner replaces the icon while it
  runs, a red dot marks a production target, and • an edited file. A separator follows the
  pinned tabs. Hover for the full title and target.
- **In the vertical tabs:** a **Pinned** section at the top, with one-line rows: the kind's
  icon, the title (• when edited), the run state (a spinner, then the last run's status dot), and
  the target's colour stripe. Selection looks as it does on the cards, and there is no close
  button.
- **Closing:**
  - Close Other Tabs and Close Tabs to the Right leave pinned tabs open, and are disabled when
    they would close nothing.
  - **⌘W asks first:** Close Tab (⌘W, or File ▸ Close Tab) on a pinned tab shows a sheet, *Close
    pinned tab?*, that names the tab: **Close** (Return) closes it, **Cancel** (Esc) keeps it.
    ⌘W while the sheet is up cancels it, and never closes the tab behind it. With a terminal
    focused, ⌘W still closes the terminal tab.
  - **Close in the tab's context menu** closes a pinned tab without asking: it is a click on
    that very tab.
  - **⇧⌘T brings a closed pinned tab back pinned:** Reopen Closed Tab puts it back at its old
    place among the pinned tabs (the last pinned tab if fewer are pinned now). A reopened
    unpinned tab never lands among the pinned ones: it goes after them.
- **Saved:** the pin is saved with the session (`"pinned": true` on the tab in
  `State/session.json`) and in `.runlet` workspaces, and restored after a relaunch. Sessions and
  workspaces from before pinned tabs open with no tab pinned. Duplicate gives an unpinned copy.
- **Windows:** pins belong to a window's tabs. Tabs don't move between windows.

## For developers

| Piece | Where |
| --- | --- |
| The order rules: pin, unpin, new tab position, moves, reopened tabs, Close Others, Close to the Right, ⌘-numbers | `TabPinOrder` in `Packages/RunletKit/Sources/RunletCore/TabPins.swift`, tested in `TabPinsTests` |
| Which closes ask first (only Close Tab on a pinned tab) | `TabPinning.asksBeforeClosing(pinned:request:)` (RunletCore); the sheet is `AppModel.closeTabForCommandW` |
| The pin in sessions and workspaces | `TabState.pinned`, `WorkspaceTab.pinned` (RunletCore) |
| The context menu's items | `TabMenuItem.items(for:pinned:)` (RunletCore), shown by `TabContextMenu` |
| Applying the rules to a window | `WindowModel.pinOrder` / `apply(_:)`; `AppModel.setPinned(_:for:)`, `moveTab`, `closeOtherTabs`, `closeTabsToRight` |
| The views | `TabStrip` (`MainWindow.swift`), `VerticalTabList` (`VerticalTabs.swift`), `PinnedTabs.swift` |
| Renaming: what Return, Esc, and a focus loss do with the name, when the field takes the keyboard back, Open Anything's words | `TabRename` (RunletCore), tested in `TabRenameTests` |
| The rename field, shared by both layouts and pinned tabs | `TabRenameField` and `TabRenameTextField` (`TabRenameField.swift`); the rename in progress is `WindowModel.rename`, started by `AppModel.beginRename(_:)` |

Debug builds have the rename steps `rename-begin:<tab title>` (as Rename… in the context menu),
`rename-begin-steal:<tab title>`, `rename-state`, `rename-type:<text>`, `rename-key:<key>`, and
`rename-blur:editor|click` (see `TabRenameDebugSteps.swift`); `scripts/tab-rename-check.py` checks
renaming in both layouts, for pinned tabs, and from the palettes, with scratch data, and takes the
pull request's screenshots.

Debug builds have the steps `pin:<tab title>`, `unpin:<tab title>`, `move-tab:<tab title>=<index>`,
`pins-state`, and `pinned-close:close|cancel|state`, which answers or prints the sheet that
`perform:file.closeTab` (⌘W) shows for a pinned tab (see `DebugSteps.swift`). `scripts/pinned-tabs-screenshots.py` checks the rules
end to end with scratch data and takes the pull request's screenshots.
