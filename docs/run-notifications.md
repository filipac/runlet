# Notifications for long runs

Start a long data fix or import, switch to another app, and Runlet tells you when it ends
([#26](https://github.com/filipac/runlet/issues/26)).

![Settings ▸ General ▸ Notifications](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-26/settings-notifications.png)

## When Runlet notifies

A run posts a macOS notification when all of these hold:

- **Settings ▸ General ▸ Notifications ▸ Notify when a long run finishes in the background** is on.
  It is on by default.
- The run took at least the time under **Notify after**: 10 seconds (the default), 30 seconds,
  1 minute, or 5 minutes.
  - The time counts from pressing Run, or from confirming a production run or approving an AI
    client's request, until the run ends. Connecting to an SSH host or resolving a container counts
    too.
- You can't see the run end:
  - Runlet isn't the active app (you switched to another app, or hid Runlet);
  - or the tab's window is minimized.

  A run that ends while you look at Runlet (even in another of its windows) doesn't notify.

These runs count: Run, Run Selection, Profile Run, an SQL tab's Run and Run All Statements, and runs
an AI client asked for over MCP. So does a run that couldn't start after a long wait, such as an SSH
connection that timed out.

These never notify:

- a run you stopped;
- a sandbox auto-run;
- App Info, schema loads, the Commands pane's command lists, and commands in the terminal: they
  aren't runs.

## What the notification says

Only four facts:

- the status: completed, failed, ended unexpectedly, or couldn't start;
- the duration;
- the tab's title;
- the target's name.

For example, **Run completed in 1 min 5 s** with **Import users · Shop (Docker)** below it.

The notification never contains your code, its output, error messages, SQL, or values. They stay in
the tab. Each tab has at most one notification: a newer run's notification replaces the previous one.

Click the notification to go back. Runlet comes forward with the window and tab that ran, even if
the window was minimized or another tab was selected. If you closed the tab meanwhile, Runlet only
comes forward.

## Permission

macOS asks whether Runlet may show notifications:

- the first time Runlet has a notification to show;
- or when you turn the switch on in Settings.

Runlet asks only then, and never again once you answer.

Under the switch, Settings shows macOS's answer:

- **Allowed**;
- **macOS asks the first time there's one to show**: macOS hasn't asked yet;
- **Notifications are off for Runlet**: you declined, or turned Runlet off in System Settings.
  **Open Notification Settings…** opens System Settings ▸ Notifications. Runlet changes nothing
  there; turn Allow notifications on for Runlet yourself. Settings shows the change when you come
  back.

![Notifications turned off in System Settings](https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-26/settings-notifications-denied.png)

Banners, sounds, and the Notification Center list follow your choices for Runlet in System Settings
▸ Notifications.

### Ad-hoc signed builds

Releases are ad-hoc signed until Developer ID signing lands
([#24](https://github.com/filipac/runlet/issues/24)). macOS keeps notification permission per bundle
identifier, so a build with another identifier (a Debug build, for example) is a separate entry in
System Settings ▸ Notifications. If macOS refuses notifications for a build altogether, Settings
shows **macOS can't show Runlet's notifications** with macOS's reason, and runs go on as usual.

## Development

Debug builds started with `RUNLET_DEBUG_STEPS`, `RUNLET_DEBUG_INSPECTOR`, or `RUNLET_SNAPSHOT_DIR`
(the screenshot and step scripts) never post notifications or ask macOS for permission. Instead they
print the notification that would be posted to stderr:

```text
RUNLET_DEBUG_NOTIFICATION: id=runlet.run.<tab id> title="Run completed in 11 s" body="Tab 1 · Laravel Sandbox 13.34.0" window=<window id> tab=<tab id>
```

Other Debug launches can choose:

- `RUNLET_DEBUG_NOTIFICATIONS=log[:allowed|denied|notDetermined|unavailable]` logs, and reports
  that permission;
- `RUNLET_DEBUG_NOTIFICATIONS=system` uses macOS notifications, even in a scripted run.

These steps go with them (see `Runlet/App/DebugSteps.swift`):

- `notifications:<state>` sets the permission the logging notifier reports;
- `notification-click` handles a click on the last logged notification;
- `notification-state` prints the setting, the permission, and the last notification.

For example, this run checks that an 11-second run in the background notifies, and that a click
brings back its tab from another one:

```sh
printf '<?php\nsleep(11);\n' > /tmp/sleep.php
open -g -j -n -W --env RUNLET_DATA_DIR=/tmp/runlet-scratch --env RUNLET_SNAPSHOT_DIR=/tmp/runlet-shots \
  --env RUNLET_DEBUG_STEPS="ghost,code:/tmp/sleep.php,run,wait-run:60,notification-state,perform:file.newTab,notification-click,state" \
  --stderr /tmp/runlet.log build/DerivedData/Build/Products/Debug/Runlet.app
grep -E 'NOTIFICATION|notification' /tmp/runlet.log
```

The decision, the text, and the permission flow are in
`Packages/RunletKit/Sources/RunletCore/RunNotifications.swift`, tested by `RunNotificationTests`
with a fake poster.
