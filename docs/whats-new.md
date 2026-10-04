# Guided tour and What's New

Runlet introduces itself on the first launch, and says what changed after an update
([#232](https://github.com/filipac/runlet/issues/232)).

## The guided tour

The very first time Runlet starts, a short tour walks through the main window with **coach
marks**: a card that points at the real control, with a ring around it, a short text, and Back,
Next, and Skip Tour. It shows where you are ("3 of 8") and has eight stops:

1. the target menu (the sandbox, a project, Docker, or SSH);
2. Run (⌘R) and Run Selection;
3. the output's Structured, Plain, and Raw modes, and the queries, mail, and logs a run records;
4. History, snippets, and the Database pane;
5. Open Anything (⌘P);
6. SQL, Redis, and MongoDB tabs, and their builder (⌥⌘B);
7. the status bar's connection count, which opens the Connection Manager;
8. Settings.

**Help ▸ Show Tour** plays it again, and so does **Show Tour** in Open Anything.

A stop whose control isn't on screen opens it if that is harmless (the History & Snippets panel,
the output pane); the History & Snippets panel goes back as it was when the tour ends. Otherwise the stop is
shown in the middle of the window with a small picture of the menu item and its shortcut, and
says where the control is (a Redis tab's Builder button, for example). The tour never runs code,
connects anywhere, changes data, or opens a project.

## What's New

The first time a newer version or build starts (betas too, and whatever installed it: a download,
the updater, a relaunch), the **What's New** window shows the highlights of every version since
the one you last opened, newest first. Each feature has a title, a sentence or two, and **Show
Me**, which hides the window, runs a short coach-mark tour of that feature over the main window,
and brings the window back. Important features are on banner cards at the top; the rest follow
in a grid, then **Also in this version**, a link to the release notes, and **Full Changelog**.
A feature behind a feature flag says so, and whether the flag is on.

**Help ▸ What's New** and **What's New in Runlet** in Open Anything open it any time, with the
current version's highlights.

## When they appear

They appear by themselves only on an ordinary launch, and wait for a quiet moment:

- never while a run (PHP, SQL, Redis, MongoDB, an AI client's) is in progress, a sheet or alert is
  open (an AI client's approval, a production confirmation), the palette or the Software Update
  window is open, you are typing, or Runlet is in the background; they wait until that's over
  (for up to 15 minutes, then until the next launch);
- never when Runlet starts for `runlet mcp` (it passes `--launched-by-mcp`, which the updater
  reads too), for `--self-test` (which is also what packaging runs), or for UI tests;
- never with a scratch `RUNLET_DATA_DIR` (snapshots, screenshots, scripted checks, and every UI
  test use one), unless a DEBUG step asks for them (see below).

Someone new gets the tour and no What's New for the version they started with. Someone who used
an earlier Runlet gets What's New instead of the tour; if that Runlet was older than What's New
itself, the window shows everything in the current version.

## Settings

**Settings ▸ General ▸ Tips** has **Show What's New after updates** and **Show tips on first
launch** (both on by default, saved in `settings.json` as `showWhatsNewAfterUpdates` and
`showTipsOnFirstLaunch`), and buttons for both. The What's New window has the first switch too.
With What's New off, a new version still counts as seen, so turning it back on doesn't bring back
old entries.

What was seen is kept in `State/onboarding.json`: whether this data folder belonged to a new user
(decided when the file is first written, from whether an earlier Runlet left `settings.json`,
`session.json`, `history.json`, `snippets.json`, `targets.json`, or `facts.json`), the tour's
status (`started`, `finished`, or `skipped`), and the last version and build What's New was shown
for (`whatsNewSeen`).

## Keyboard and VoiceOver

- **Return** is Next (Done on the last stop) and **Esc** is Skip Tour (Close in a Show Me tour);
  in What's New, Return is Continue and Esc closes the window.
- The card takes the keyboard only when you aren't typing. If a stop appears while you type in
  the editor, your keys keep going to the editor; click the card (or its buttons) to use it.
- VoiceOver announces each stop ("Tour, step 3 of 8. Read the output. …") whether or not the card
  has the keyboard, and reads the card as a group with its buttons.

## Adding entries for a release

Before a pre-release or a release, add What's New entries for its important features to
`Runlet/WhatsNew.json`, under the version and build the release commit sets in `project.yml`
(`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; see [Releasing](releasing.md#every-release)).
Each beta build gets its own entry, with its label ("0.4.0 beta 7"); the window aggregates every
build since the one last seen.

```json
{
  "version": "0.4.0",
  "build": 14,
  "label": "0.4.0 beta 8",
  "date": "2026-10-05",
  "notes": "https://github.com/filipac/runlet/releases/tag/v0.4.0-beta.8",
  "features": [
    {
      "id": "in-app-updates",
      "title": "In-app updates",
      "text": "One or two sentences.",
      "symbol": "arrow.down.circle",
      "important": true,
      "tour": [
        { "title": "Check for updates", "text": "…", "menu": "Runlet ▸ Check for Updates…", "command": "app.checkForUpdates" }
      ]
    }
  ],
  "also": ["A short line about a smaller change."]
}
```

A Show Me step that points at a control names its `anchor`, for example
`{ "anchor": "dry-run-toggle", "title": "Turn on Dry Run", "text": "…" }`; without one, the stop is
centred with its menu path and shortcut.

- **Features**: `id` (unique, lowercase words with dashes), `title`, `text`, an SF Symbol
  (`symbol`), `important` for a banner card, an optional `image` from the asset catalog, an
  optional `flag` (a `FeatureFlag` id), and `tour`, Show Me's steps.
- **Steps** (also the first-launch tour's, under `tour` at the top of the file): `title`, `text`,
  and at least one of `anchor` (a `TourAnchor` id), `menu` ("View ▸ Logs"), `command` (a command
  id, whose shortcut is shown as the user mapped it), or `keys` ("⌥↑ ⌥↓"); `prepare` opens a
  harmless panel first (`inspector-history`, `inspector-snippets`, `inspector-database`,
  `output-pane`); `symbol` draws a centred stop's picture.
- **Anchors**: views mark themselves with `.tourAnchor(.runButton)`; the ids are the cases of
  `TourAnchor` (`RunletCore/WhatsNew.swift`): `target-menu`, `run-button`, `dry-run-toggle`,
  `inspector-toggle`, `library-pane-picker`, `new-tab-button`, `editor`, `output-mode-picker`,
  `output-pane`, `connections-status`, `language-status`, `database-tab-bar`, `connection-picker`,
  and `builder-button`. Add a case and the modifier to point at something new.

Checks: `WhatsNewTests` (RunletCore) fail when an entry doesn't parse, a step names an anchor that
isn't in `TourAnchor` or that no view marks, a command that isn't in the catalog, or a flag that
doesn't exist, or when `project.yml`'s version has no entry of its own. Only a release commit sets
that version (main stays at the previous one), so a version older than the manifest's newest build
is covered by the entries written ahead of it; the release commit's version (0.4.0 build 14 for
beta 8) must have its own. The packaged self-test fails on a manifest
with problems and reports whether its version has an entry, and `scripts/package.sh` prints a
warning when the packaged version and build have none.

## For developers

- **Model** (RunletCore): `WhatsNew.swift` (`AppVersion`, `TourAnchor`, `TourPreparation`,
  `TourStep`, `WhatsNewFeature`, `WhatsNewRelease`, `WhatsNewManifest` with `releases(after:through:)`,
  `sections`, `currentSections`, `covers`, and `problems`) and `Onboarding.swift`
  (`OnboardingState`, `OnboardingLaunch.blocker`, `OnboardingActivity.waitReason`,
  `OnboardingPolicy.decide`).
- **App**: `WhatsNew.presentIfNeeded(model:)` (`AppModel+Onboarding.swift`) is the one launch
  entry point, called from `applicationDidFinishLaunching`; `OnboardingStore` reads
  `onboarding.json` before anything else is written. `CoachMarks.swift` has the anchor registry
  (`.tourAnchor`, `TourAnchors`), `TourController`, the card and ring panels, and `TypingMonitor`;
  `WhatsNewView.swift` the window and Settings ▸ General ▸ Tips.
- **DEBUG steps** (`TourDebugSteps`): `tour:start|next|back|skip|done|step:<n>|key:return|key:escape|show-me:<id>`,
  `tour-state`, `whats-new:show[:since=<version>+<build>]`, `whats-new:show-me:<id>`,
  `whats-new:close`, `whats-new-state`, `onboarding:auto` (the launch's decision with scratch
  data), `onboarding:new-user|updater[:<version>+<build>]`, and `onboarding-state`.
  `shot` draws coach marks as they are.
- **Screenshots**: `scripts/whats-new-screenshots.py /path/to/Runlet.app /path/to/output` shoots a
  tour stop, What's New (after beta 6 and after 0.3.0), and a Show Me stop, in light and dark,
  with scratch data.
