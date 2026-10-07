# Settings

Open Settings with **Runlet ▸ Settings…** (<kbd>⌘</kbd><kbd>,</kbd>). It has a tab per area, and every change is saved at once. Each option explains itself in the window; this page is a map of where things are, and covers the parts that aren't visible at first.

![Settings ▸ General, with the Appearance, Running, Notifications, and Tips sections](screenshots/settings/general-light.webp#gh-light-mode-only)
![Settings ▸ General, with the Appearance, Running, Notifications, and Tips sections](screenshots/settings/general-dark.webp#gh-dark-mode-only)

## General

| Section | What it holds |
| --- | --- |
| **Appearance** | **Appearance** (System, Light, or Dark), where the **Output pane** goes (right of or below the editor), and the **Tabs** layout (horizontal, or vertical with details). |
| **Running** | **Run prefers selection** (<kbd>⌘</kbd><kbd>R</kbd> runs only the selection when there is one) and **Declare strict_types=1 for every run**. See [Running Code](running-code.md). |
| **Notifications** | A notification when a long run finishes while Runlet is in the background: one that took 10 seconds or more, or the 30 seconds, 1 minute, or 5 minutes you choose. See [Notifications for Long Runs](run-notifications.md). |
| **Tips** | **Show What's New after updates**, **Show tips on first launch**, and **Show shortcut tips**, with buttons that open What's New and replay the tour. |
| **Output** | When a run's output appears (**Realtime** or **At once**), **Hide the output pane until a run**, and **Escape hides the output pane**. See [The Output Pane](running-code.md#the-output-pane). |
| **SQL Results** | **Rows per page** for SQL tabs: 1,000 (the default) to 10,000. See [SQL Tabs](sql-tabs.md). |
| **Magic Comments** | **Show values of magic comments**. See [Magic Comments](magic-comments.md#turning-them-off). |
| **Run Inspector** | **Record queries, mail, and logs** (on); **Record HTTP requests** (on) and **Include request and response bodies** (off); **Record jobs** (on); **Record events** (off); **Intercept mail** (off); and **Preview returned mail, views, and HTML** (on). Projects and profiles can override mail interception; the other switches apply to every target. See [Choosing What's Recorded](run-inspector.md#choosing-whats-recorded). |
| **New Tabs** | The **Default target** of new tabs: the sandbox, or one of your projects, Docker applications, or SSH hosts. |
| **History & Snippets** | What double-click (and <kbd>Return</kbd>) does in History and Snippets, how many runs History keeps (1,000 by default), and **Clear History…**. See [Run History](running-code.md#run-history). |
| **Command Palette** | **Clear Command History**, which forgets the commands you chose in the palettes, so none come first, and the counts behind shortcut tips. See [Frequently Used Commands](keyboard-shortcuts.md#frequently-used-commands). |
| **Command-Line Tool** | Installs the `runlet` command. See [Command-Line Tool](cli.md). |
| **Updates** | The update **Channel** (Stable or Beta), **Check for updates automatically**, and **Check Now**. See [Updating Runlet](installation.md#updating-runlet). |

## Editor

| Section | What it holds |
| --- | --- |
| **Text** | The editor's **Font**, **Font size** (13 pt by default), **Line height**, **Ligatures**, and **Wrap long lines**. |
| **Indentation** | **Tab width** (2, 4, or 8) and **Insert spaces instead of tabs** (on). |
| **Formatting** | The **Style**, **Quotes**, and **Format before run** of [Format Code](format-code.md#settings). |
| **External Editor** | The editor that file paths in the output open in, at their line: one that's installed, or a **Custom Command…** such as `code --goto {file}:{line}`. **Test** opens the current project in it. |
| **Language Service** | **PHPantom code intelligence:** completion, hover, signature help, diagnostics, and [code navigation](navigation.md). |

## Targets and Runtimes

| Tab | What it holds |
| --- | --- |
| **PHP** | The **Default PHP** for local projects that don't choose their own, the PHP installations Runlet found (with **Rescan**), and **Runlet's PHP**, which you can download, update, or remove. See [Your First Run](installation.md#your-first-run). |
| **Docker** | Whether Docker is running, and an optional path to the `docker` command. |
| **Sandbox** | The bundled Laravel sandbox: its version, where it's kept, **Run sandbox with** (Automatic, Local PHP, or Docker), and **Reset Sandbox…**, which restores a fresh copy and leaves your projects, snippets, and history alone. |
| **Targets** | Your local projects, Docker profiles, and SSH hosts, with **Edit…**, **Manage Profiles…**, and **Import from ~/.ssh/config…**. See [SSH Targets](ssh.md). |
| **Databases** | Saved database connections for all targets and for each target. See [Connections ▸ Saved Connections](connections.md#saved-connections). |

## AI Clients and Shortcuts

- **AI Clients** turns on the connection for AI clients such as Claude Code and Cursor (off by default), lists the connected clients with **Revoke**, and shows how to set up a client. See [AI Clients (MCP)](mcp.md).
- **Shortcuts** changes the shortcut of any command. See [Keyboard Shortcuts](keyboard-shortcuts.md#changing-shortcuts). At the top, **Open Quick Run from any app** turns on the [Quick Run](quick-run.md#the-global-shortcut) panel's global shortcut (off by default; <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> unless you record another), and says when another app, macOS, or one of Runlet's commands already uses it.

## Tips

**Settings ▸ General ▸ Tips** has **Show What's New after updates** and **Show tips on first launch**, both on by default, with buttons that open What's New and replay the guided tour. **Help ▸ What's New in Runlet** and **Help ▸ Show Tour** open them too.

**Show shortcut tips**, also on by default, shows a command's keyboard shortcut in a small tip after you click its menu item or button, or choose it in a palette: at most once a day for each command, until you've used the shortcut three times. See [Keyboard Shortcuts ▸ Learning Shortcuts](keyboard-shortcuts.md#learning-shortcuts).

## Advanced (Feature Flags)

**Settings ▸ Advanced** lists **feature flags**: hidden or experimental features, each with a title, a short description, and a switch. Every flag is off by default.

- **Showing the tab.** It's hidden at first. Press <kbd>⌥</kbd><kbd>⌘</kbd><kbd>,</kbd>, or hold <kbd>⌥</kbd> while you choose **Runlet ▸ Settings…**, and Settings opens on **Advanced**. The tab then stays until you click **Hide Advanced Settings** at its bottom. Nothing in the menus shows it.
- **Turning a flag off** hides the feature's buttons and sheets again. It never deletes what the feature created: connections imported from TablePlus, for example, stay.

| Flag | What it adds |
| --- | --- |
| Import connections from TablePlus | **Import from TablePlus…** in **Settings ▸ Databases** and Edit Connections. See [Connections ▸ Import From TablePlus](connections.md#import-from-tableplus). |

## Where Settings Are Kept

Settings are saved in `State/settings.json` in Runlet's data folder, `~/Library/Application Support/Runlet`. They stay across updates.

## For developers

- Settings are `AppSettings` (`Models.swift`, RunletCore), saved as `State/settings.json` in Runlet's data folder (`RUNLET_DATA_DIR` for scratch data). The window is `SettingsView.swift`; each tab is a view of its own (`TargetSettingsView`, `DatabaseSettingsView`, `ShortcutSettingsView`, `AIClientsSettingsTab` in `MCPViews.swift`). See [Architecture](architecture.md) for the full list of keys.
- **Quick Run** ([#25](https://github.com/filipac/runlet/issues/25)): `quickRunHotKeyEnabled` (false) and `quickRunHotKey` (the key code and combo; ⌃⌥R by default), in `QuickRunHotKeySettings` at the top of `ShortcutSettingsView`. See [Quick Run](quick-run.md#for-developers).
- **Tips** ([#232](https://github.com/filipac/runlet/issues/232)): `showWhatsNewAfterUpdates` and `showTipsOnFirstLaunch`. What was already seen is kept in `State/onboarding.json`, not in the settings. See [What's New](whats-new.md). `shortcutTips` ([#345](https://github.com/filipac/runlet/issues/345)) turns shortcut tips on and off; their counts are kept in `State/shortcut-tips.json`. See [Keyboard Shortcuts ▸ For developers](keyboard-shortcuts.md#for-developers).
- **Command Palette** ([#328](https://github.com/filipac/runlet/issues/328)): the commands' uses are kept in `State/command-usage.json`, not in the settings. See [Keyboard Shortcuts ▸ For developers](keyboard-shortcuts.md#for-developers).
- **Feature flags** ([#187](https://github.com/filipac/runlet/issues/187)):
  - `settings.json` keeps them under `featureFlags` (flag id → true or false), and the tab's visibility as `showAdvancedSettings`. Settings files from before flags existed load with every flag off. Flags this Runlet doesn't know (from a newer or older Runlet) are kept as they are and saved again; a value that isn't true or false is dropped without affecting the others. A scratch `RUNLET_DATA_DIR` has its own `settings.json`, so its own flags.
  - Debug builds only: `RUNLET_FEATURE_FLAGS=a,b` turns flags on for screenshots and scripted checks; their switches show that and can't turn them off. Release builds ignore the variable.
  - The flags are registered in `FeatureFlag.all` (`RunletCore/FeatureFlags.swift`: `id`, title, summary, issue, default), and code checks one only through `AppModel.isEnabled(_:)` (`AppSettings.isEnabled(_:forcedOn:)` underneath). The tab is `AdvancedSettingsView`; the ⌥ trigger is `AdvancedSettingsTrigger` (`AppModel+FeatureFlags.swift`). Tests: `FeatureFlagTests`.
  - The TablePlus flag's id is `tablePlusImport` ([#188](https://github.com/filipac/runlet/issues/188)).
