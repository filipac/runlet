# Settings

Runlet ▸ Settings… (⌘,) has a tab per area: General, Editor, PHP, Docker, Sandbox, AI Clients,
Targets, Databases, and Shortcuts. Every change is saved at once in `State/settings.json` in
Runlet's data folder (`RUNLET_DATA_DIR` for scratch data). Each tab explains its own options;
this page covers what isn't visible at first.

## Tips

**Settings ▸ General ▸ Tips** ([#232](https://github.com/filipac/runlet/issues/232)) has **Show
What's New after updates** and **Show tips on first launch** (both on; `showWhatsNewAfterUpdates`
and `showTipsOnFirstLaunch` in `settings.json`), with buttons that open What's New and replay the
guided tour. What was already seen is kept in `State/onboarding.json`, not in the settings. See
[What's New](whats-new.md).

## Advanced (feature flags)

**Settings ▸ Advanced** ([#187](https://github.com/filipac/runlet/issues/187)) lists **feature
flags**: hidden or experimental features, each with a title, a one-line description, and a
switch. Every flag is off by default.

- **Showing the tab.** It's hidden at first. Press **⌥⌘,**, or hold **⌥** while choosing
  Settings… in the Runlet menu, and Settings opens on Advanced. It then stays until you click
  **Hide Advanced Settings** at the bottom of the tab. Nothing in the menus shows it.
- **Turning a flag off** hides the feature's buttons and sheets again. It never deletes what the
  feature created: connections imported from TablePlus, for example, stay.
- **Storage.** `settings.json` keeps the flags under `featureFlags` (flag id → true or false)
  and the tab's visibility as `showAdvancedSettings`. Settings files from before flags existed
  load with every flag off. Flags this Runlet doesn't know (from a newer or older Runlet) are
  kept as they are and saved again; a value that isn't true or false is dropped without
  affecting the others. A scratch `RUNLET_DATA_DIR` has its own `settings.json`, so its own
  flags.
- **Debug builds only:** `RUNLET_FEATURE_FLAGS=a,b` turns flags on for screenshots and scripted
  checks; their switches show that and can't turn them off. Release builds ignore the variable.

| Flag | Id | What it adds |
| --- | --- | --- |
| Import connections from TablePlus | `tablePlusImport` | **Import from TablePlus…** in Settings ▸ Databases and Edit Connections ([#188](https://github.com/filipac/runlet/issues/188); see [SQL tabs](sql-tabs.md#import-from-tableplus)) |

For developers: the flags are registered in `FeatureFlag.all` (`RunletCore/FeatureFlags.swift`:
`id`, title, summary, issue, default), and code checks one only through `AppModel.isEnabled(_:)`
(`AppSettings.isEnabled(_:forcedOn:)` underneath). The tab is `AdvancedSettingsView`; the ⌥
trigger is `AdvancedSettingsTrigger` (`AppModel+FeatureFlags.swift`). Tests:
`FeatureFlagTests`.
