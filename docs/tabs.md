# Tabs

Every window has tabs, and each tab is a PHP, SQL ([SQL tabs](sql-tabs.md)), Redis
([Redis](redis.md)), or MongoDB ([MongoDB](mongodb.md)) tab with its own target and code. Tabs
are saved with the session and restored after a relaunch; restoring a tab never runs its code.
Pinned tabs were added under [#279](https://github.com/filipac/runlet/issues/279).

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
| Rename | Double-click the tab, **Rename…** in its context menu, or **Window ▸ Rename Tab…** |
| Duplicate | **Duplicate** in its context menu, or **File ▸ Duplicate Tab** (⇧⌘D) |
| Close | The close button, **Close** in its context menu, or **File ▸ Close Tab** (⌘W) |
| Close the others | **Close Other Tabs** in its context menu, or **Window ▸ Close Other Tabs** |
| Close to the right | **Window ▸ Close Tabs to the Right** |
| Reopen a closed tab | **Window ▸ Reopen Closed Tab** (⇧⌘T): the last 20 closed tabs that had code |
| Select | Click it, ⇧⌘] and ⇧⌘[ for the next and previous tab, ⌘1…⌘8 for the nth tab, ⌘9 for the last |
| Pin or unpin | **Pin Tab** / **Unpin Tab** in its context menu, or **Window ▸ Pin Tab** (see [Pinned tabs](#pinned-tabs)) |

The tab bar and the vertical tabs share one context menu: Rename…, Duplicate, Pin Tab (or
Unpin Tab), Switch to … for every other tab language, Close, and Close Other Tabs. Every Window
menu command is also in the command palette (⇧⌘P), where Settings ▸ Shortcuts can give it a
shortcut.

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
- **Closing:** Close Other Tabs and Close Tabs to the Right leave pinned tabs open, and are
  disabled when they would close nothing. ⌘W, or Close in its context menu, still closes a
  pinned tab, as in browsers, and Reopen Closed Tab (⇧⌘T) brings it back pinned.
- **Saved:** the pin is saved with the session (`"pinned": true` on the tab in
  `State/session.json`) and in `.runlet` workspaces, and restored after a relaunch. Sessions and
  workspaces from before pinned tabs open with no tab pinned. Duplicate gives an unpinned copy.
- **Windows:** pins belong to a window's tabs. Tabs don't move between windows.

## For developers

| Piece | Where |
| --- | --- |
| The order rules: pin, unpin, new tab position, moves, Close Others, Close to the Right, ⌘-numbers | `TabPinOrder` in `Packages/RunletKit/Sources/RunletCore/TabPins.swift`, tested in `TabPinsTests` |
| The pin in sessions and workspaces | `TabState.pinned`, `WorkspaceTab.pinned` (RunletCore) |
| The context menu's items | `TabMenuItem.items(for:pinned:)` (RunletCore), shown by `TabContextMenu` |
| Applying the rules to a window | `WindowModel.pinOrder` / `apply(_:)`; `AppModel.setPinned(_:for:)`, `moveTab`, `closeOtherTabs`, `closeTabsToRight` |
| The views | `TabStrip` (`MainWindow.swift`), `VerticalTabList` (`VerticalTabs.swift`), `PinnedTabs.swift` |

Debug builds have the steps `pin:<tab title>`, `unpin:<tab title>`, `move-tab:<tab title>=<index>`,
and `pins-state` (see `DebugSteps.swift`). `scripts/pinned-tabs-screenshots.py` checks the rules
end to end with scratch data and takes the pull request's screenshots.
