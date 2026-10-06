# Tabs

Every Runlet window holds tabs, and each tab has its own code and its own target. A tab is a PHP tab, an [SQL tab](sql-tabs.md), a [Redis tab](redis.md), or a [MongoDB tab](mongodb.md).

Tabs are saved with your session and come back after a relaunch. Restoring a tab never runs its code: nothing runs until you press Run.

## Horizontal and Vertical Tabs

Runlet shows tabs in one of two layouts:

- **Horizontal:** a tab bar above the editor. Each tab shows its target's icon and its title, a badge for SQL, Redis, and MongoDB tabs, PRODUCTION for a production target, a spinner while it runs, and a close button. Drag a tab along the bar to reorder the tabs.
- **Vertical:** a sidebar of tab cards. Each card shows the target, its runtime and PHP version, and the framework or `.runlet` driver of the last run. Drag a card to reorder the tabs, and drag the sidebar's edge to resize it.

To switch layouts, choose **View ▸ Toggle Vertical Tabs** (<kbd>⌃</kbd><kbd>⌘</kbd><kbd>T</kbd>), click the toolbar button, or change **Settings ▸ General ▸ Tabs**. The layout applies to every window.

## Working With Tabs

| Action | How |
| --- | --- |
| New tab | **File ▸ New Tab** (<kbd>⌘</kbd><kbd>T</kbd>), or **+** in the tab bar or the sidebar. The File menu also has **New SQL Tab**, **New Redis Tab**, and **New MongoDB Tab**. |
| Rename | Double-click the tab, choose **Rename…** in its context menu, or **Window ▸ Rename Tab…**. See [Renaming a tab](#renaming-a-tab). |
| Duplicate | **Duplicate** in its context menu, or **File ▸ Duplicate Tab** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd>). |
| Close | The close button, **Close** in its context menu, or **File ▸ Close Tab** (<kbd>⌘</kbd><kbd>W</kbd>). |
| Close the others | **Close Other Tabs** in its context menu, or **Window ▸ Close Other Tabs**. |
| Close to the right | **Window ▸ Close Tabs to the Right**. |
| Reopen a closed tab | **Window ▸ Reopen Closed Tab** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd>) brings back the last 20 closed tabs that had code. |
| Select | Click it. <kbd>⇧</kbd><kbd>⌘</kbd><kbd>]</kbd> and <kbd>⇧</kbd><kbd>⌘</kbd><kbd>[</kbd> select the next and previous tab, <kbd>⌘</kbd><kbd>1</kbd> to <kbd>⌘</kbd><kbd>8</kbd> the tab at that position, and <kbd>⌘</kbd><kbd>9</kbd> the last tab. |
| Pin or unpin | **Pin Tab** or **Unpin Tab** in its context menu, or **Window ▸ Pin Tab**. See [Pinned tabs](#pinned-tabs). |
| Reorder | Drag the tab along the tab bar, or its card in the vertical tabs. **Move Tab Left** and **Move Tab Right** in the command palette move the selected tab one place. See [Reordering tabs](#reordering-tabs). |

The tab bar and the vertical tabs share one context menu: **Rename…**, **Duplicate**, **Pin Tab** (or **Unpin Tab**), **Switch to …** for every other tab language, **Close**, and **Close Other Tabs**.

> [!TIP]
> Every Window menu command is also in the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>), and **Settings ▸ Shortcuts** can give any of them a shortcut.

## Reordering Tabs

Tabs stay in the order you put them in, in both layouts: the tab bar and the vertical tabs show the same order, and it is saved with your session.

- **In the tab bar,** drag a tab left or right. It follows the pointer and is selected, and the tabs it passes slide aside to show where it will land. Release it to drop it there.
- **In the vertical tabs,** drag a card up or down, and drop it where the line shows.
- **From the keyboard,** run **Move Tab Left** or **Move Tab Right** from the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>). They move the selected tab one place. They have no shortcut; **Settings ▸ Shortcuts** can give them one.

With more tabs than fit in the tab bar, hold the dragged tab near either end of the bar, and the bar scrolls that way. The closer to the end, the faster it scrolls.

A tab moves only when you drag it a few points. A click still selects it, a double-click still renames it, and the close button and the context menu work as usual. While you rename a tab, dragging in its field selects text.

A dragged tab stays in its group: a [pinned tab](#pinned-tabs) moves among the pinned tabs, and any other tab among the others. Drag a tab toward the other group, and it stops at its own group's end. Tabs don't move between windows.

## Renaming a Tab

Renaming works the same way in the tab bar, the vertical tabs, and pinned tabs in both layouts.

To start renaming, double-click the tab, choose **Rename…** in its context menu, or choose **Window ▸ Rename Tab…** for the selected tab. You can also run **Rename Tab…** from the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>), or type "rename" in Open Anything (<kbd>⌘</kbd><kbd>P</kbd>).

The title turns into a field with the whole title selected, so typing replaces it. Click in the field to place the caret or select a word; the click doesn't select the tab or start a drag. While you rename, keys go to the field, never to the editor, and <kbd>⌘</kbd><kbd>W</kbd> closes nothing.

| To | Press |
| --- | --- |
| Keep the new name | <kbd>Return</kbd> or <kbd>Tab</kbd>, or click anywhere else: in the editor, on another tab, or on an empty part of the tab bar. |
| Keep the old name | <kbd>Esc</kbd>. It does nothing else: it doesn't hide the output pane. |

Runlet trims the name, and an empty name keeps the old title. After <kbd>Return</kbd> or <kbd>Esc</kbd>, the editor (or whatever had the keyboard before) has the keyboard again.

## Pinned Tabs

Pin the tabs you keep open all the time, such as a scratch snippet, a production SQL tab, or a Redis tab. Any kind of tab can be pinned, in both layouts.

### Pinning a Tab

Choose **Pin Tab** in the tab's context menu, or **Window ▸ Pin Tab** for the selected tab (it shows a checkmark while the tab is pinned). The command palette has **Pin Tab** too, and Open Anything lists it when you type "pin" or "unpin". Pinning never runs anything.

Pinned tabs come first: leftmost in the tab bar, and at the top of the vertical tabs.

- Pinning moves a tab to the end of the pinned tabs; unpinning moves it to the start of the other tabs.
- New tabs open after the pinned ones, even when a pinned tab is selected.
- A dragged tab stays in its group. In the tab bar, a tab dragged toward the other group stops at its own group's end; in the vertical tabs, pinned and other tabs are separate sections, and a tab dropped past its group's end stays at that end. See [Reordering tabs](#reordering-tabs).
- <kbd>⌘</kbd><kbd>1</kbd> to <kbd>⌘</kbd><kbd>9</kbd> count the tabs as you see them, pinned tabs first.

### How Pinned Tabs Look

- **In the tab bar,** a pinned tab is compact: its kind's icon in its colour (PHP, SQL, Redis, or MongoDB), a short title, and no close button. A spinner replaces the icon while it runs, a red dot marks a production target, and • an edited file. A separator follows the pinned tabs. Hover over one for its full title and target.
- **In the vertical tabs,** a **Pinned** section at the top lists them in one-line rows: the kind's icon, the title (with • when edited), the run state (a spinner, then the last run's status dot), and the target's colour stripe. There is no close button.

### Closing a Pinned Tab

Pinned tabs are hard to close by accident:

- **<kbd>⌘</kbd><kbd>W</kbd> asks first.** Close Tab on a pinned tab shows a sheet, *Close pinned tab?*, that names the tab. **Close** (<kbd>Return</kbd>) closes it, and **Cancel** (<kbd>Esc</kbd>) keeps it. Pressing <kbd>⌘</kbd><kbd>W</kbd> again while the sheet is up cancels it. With a terminal focused, <kbd>⌘</kbd><kbd>W</kbd> still closes the terminal tab.
- **Close Other Tabs and Close Tabs to the Right leave pinned tabs open,** and are disabled when they would close nothing.
- **Close in the tab's own context menu** closes a pinned tab without asking, since you clicked that very tab.

<kbd>⇧</kbd><kbd>⌘</kbd><kbd>T</kbd> brings a closed pinned tab back pinned, at its old place among the pinned tabs (or as the last pinned tab, if fewer are pinned now). A reopened unpinned tab never lands among the pinned ones.

### What Is Saved

Pins are saved with your session and in `.runlet` workspaces, and come back after a relaunch. **Duplicate** gives an unpinned copy. Pins belong to a window's tabs: tabs don't move between windows.

## For developers

Pinned tabs were added under [#279](https://github.com/filipac/runlet/issues/279), the rename field under [#285](https://github.com/filipac/runlet/issues/285), and dragging in the tab bar under [#322](https://github.com/filipac/runlet/issues/322).

| Piece | Where |
| --- | --- |
| The order rules: pin, unpin, new tab position, moves, reopened tabs, Close Others, Close to the Right, ⌘-numbers | `TabPinOrder` in `Packages/RunletKit/Sources/RunletCore/TabPins.swift`, tested in `TabPinsTests` |
| Which closes ask first (only Close Tab on a pinned tab) | `TabPinning.asksBeforeClosing(pinned:request:)` (RunletCore); the sheet is `AppModel.closeTabForCommandW` |
| The pin in sessions and workspaces | `TabState.pinned`, `WorkspaceTab.pinned` (RunletCore): `"pinned": true` on the tab in `State/session.json` and in `.runlet` workspaces. Sessions and workspaces from before pinned tabs open with no tab pinned. |
| The context menu's items | `TabMenuItem.items(for:pinned:)` (RunletCore), shown by `TabContextMenu` |
| Applying the rules to a window | `WindowModel.pinOrder` / `apply(_:)`; `AppModel.setPinned(_:for:)`, `moveTab`, `closeOtherTabs`, `closeTabsToRight` |
| The views | `TabStrip` (`MainWindow.swift`), `VerticalTabList` (`VerticalTabs.swift`), `PinnedTabs.swift` |
| Renaming: what Return, Esc, and a focus loss do with the name, when the field takes the keyboard back, Open Anything's words | `TabRename` (RunletCore), tested in `TabRenameTests` |
| The rename field, shared by both layouts and pinned tabs | `TabRenameField` and `TabRenameTextField` (`TabRenameField.swift`); the rename in progress is `WindowModel.rename`, started by `AppModel.beginRename(_:)` |
| Dragging in the tab bar: where a dragged tab lands (its leading edge past a neighbour's middle), how far the passed tabs slide, the group it can't leave, and the edge-scrolling speed | `TabStripDrag` and `TabStripEdgeScroll` in `Packages/RunletKit/Sources/RunletCore/TabStripDrag.swift`, tested in `TabStripDragTests` |
| The drag in a window | `TabStripDragState` (`WindowModel.tabStripDrag`) and the `tabStripDraggable` modifier (`TabStripDrag.swift`); `TabStrip` scrolls the bar near its ends. The drop goes through `AppModel.moveTab(_:to:)`, as a move in the vertical tabs does. |
| Move Tab Left and Move Tab Right | `tabs.moveLeft` and `tabs.moveRight` (`Commands.swift`), through `TabPinOrder.neighbourIndex(of:by:)` and `AppModel.moveTab(_:by:)` |

From the palettes, the rename field takes the keyboard once the palette has closed and given its window the keyboard back, and takes it back if something grabs it within the first second.

Debug builds have the rename steps `rename-begin:<tab title>` (as Rename… in the context menu), `rename-begin-steal:<tab title>`, `rename-state`, `rename-type:<text>`, `rename-key:<key>`, and `rename-blur:editor|click` (see `TabRenameDebugSteps.swift`); `scripts/tab-rename-check.py` checks renaming in both layouts, for pinned tabs, and from the palettes, with scratch data, and takes the pull request's screenshots.

Debug builds have the steps `pin:<tab title>`, `unpin:<tab title>`, `move-tab:<tab title>=<index>`, `pins-state`, and `pinned-close:close|cancel|state`, which answers or prints the sheet that `perform:file.closeTab` (⌘W) shows for a pinned tab (see `DebugSteps.swift`). `scripts/pinned-tabs-screenshots.py` checks the rules end to end with scratch data and takes the pull request's screenshots.

The tab bar's drag is a SwiftUI `DragGesture` inside the bar, not a drag and drop: nothing from another window or app can be dropped on it, and nothing leaves the window. It starts after the pointer moves 4 points with the button down, and is off on a tab being renamed. Debug builds have the steps `tab-drag:<tab title>=<index>` (drags the tab so it lands at that position, or stops at its group's end; the pointer ends mid-bar, so nothing scrolls), `tab-drag-edge:<tab title>=start|end` (the pointer at that end of the bar, which scrolls), `tab-drag-state`, `tab-drop`, and `tab-drag-cancel` (see `TabStripDebugSteps.swift`). `scripts/tab-drag-check.py` checks the drags, the groups, edge scrolling, Move Tab Left and Right, and that the order is saved, with scratch data.
