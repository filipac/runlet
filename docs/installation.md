# Installation

Runlet is one universal app for Apple silicon and Intel Macs. Download it from GitHub, move it to Applications, and allow it once in Privacy & Security. After that, Runlet updates itself.

## Requirements

- **macOS 15 (Sequoia) or later**, on Apple silicon or Intel.
- **PHP is optional.** Runlet uses Herd, Homebrew, or the `php` on your `PATH` when it finds one. Without PHP, it offers to download its own.
- **Docker and SSH are optional.** You need them only for Docker and SSH targets.

Your projects can run on PHP 7.4 to 8.5, on your Mac, in a container, or on a server. The bundled Laravel sandbox needs PHP 8.3 or later on your Mac, Runlet's own PHP, or Docker.

## Downloading Runlet

Download `Runlet-<version>.dmg` or the `.zip` from the [latest release](https://github.com/filipac/runlet/releases/latest), and drag Runlet to your Applications folder. There is no Homebrew cask yet.

Each release lists the SHA-256 checksums of its files in `SHA256SUMS.txt`. To check your download before you open it:

```sh
shasum -a 256 ~/Downloads/Runlet-<version>.dmg
```

## Opening Runlet the First Time

Runlet is ad-hoc signed and not notarized by Apple yet, so macOS blocks it the first time you open it. You allow it once:

1. Open Runlet. macOS says it can't verify the app.
2. Open **System Settings ▸ Privacy & Security**, click **Open Anyway** next to the message about Runlet, and confirm.

Or remove the quarantine flag in Terminal instead:

```sh
/usr/bin/xattr -dr com.apple.quarantine /Applications/Runlet.app
```

Browsers mark downloaded files with the `com.apple.quarantine` attribute, and macOS checks quarantined apps for Apple's notarization before their first launch. Removing the attribute tells macOS you trust this copy.

> [!WARNING]
> Only remove the quarantine flag from a download you trust. Compare its checksum with the release's `SHA256SUMS.txt` first, or [build Runlet from source](building.md).

You do this once: updates installed from inside Runlet remove the flag themselves.

## Your First Run

The Laravel sandbox is ready in the first tab: a fresh Laravel app on SQLite, bundled with Runlet. Press <kbd>⌘</kbd><kbd>R</kbd> to run its snippet.

If your Mac has no PHP, click **Download PHP 8.5.8** in the banner above the editor first. Runlet downloads its own PHP (about 26 MB) only when you click, checks it against a SHA-256 checksum built into the app, and keeps it in Runlet's data folder. You can manage or remove it in **Settings ▸ PHP**. PHP you installed yourself always comes first.

To open one of your own projects, choose **File ▸ Open Project…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>O</kbd>) and pick its folder.

## Updating Runlet

Runlet updates itself from GitHub Releases:

- **Checking.** Runlet checks at launch and once a day while it runs. To check now, choose **Runlet ▸ Check for Updates…** (also in Open Anything, <kbd>⌘</kbd><kbd>P</kbd>). A check is one request for the list of releases, with nothing about you or your Mac.
- **The offer.** A new version shows its release notes and download size, with **Install and Relaunch**, **Later**, and **Skip This Version**. Runlet never offers an update while code runs, and never installs one until you choose.
- **Installing.** Install and Relaunch checks the update's signature, so only releases signed with Runlet's key install. It replaces the app, removes the quarantine flag, and opens the new version. If the new version doesn't start, Runlet puts back the one you had.
- **Channels.** In **Settings ▸ General ▸ Updates**, choose **Stable** (releases only) or **Beta** (pre-releases too), or turn automatic checks off. A beta build starts on Beta.

When Runlet can't replace itself, it tells you what to do:

- Running from the disk image: Runlet asks you to move it to Applications first.
- An Applications folder you can't change: macOS asks for an administrator's password.

> [!NOTE]
> Runlet 0.3.0 and earlier, and 0.4.0 betas 1 to 6, can't update themselves. Download the newest release and replace the app by hand, once. Runlet 0.4.0 needs macOS 26; on macOS 15, install 0.4.1 or later.

Your tabs, snippets, history, and targets stay in `~/Library/Application Support/Runlet` across updates. Runlet's own PHP updates separately, in **Settings ▸ PHP**.

## Installing the Command-Line Tool

The `runlet` command opens folders and files in Runlet from a terminal. To install it, choose **Runlet ▸ Install Command-Line Tool…**, pick a folder on your `PATH`, and press **Install**. Runlet creates one symbolic link to the tool inside the app.

Then open the current folder as a project:

```sh
cd ~/Code/my-app
runlet .
```

The [command-line tool](cli.md) page has everything it can do.

## For developers

- Developer ID signing and notarization, which would remove the first-launch step, are tracked in [#24](https://github.com/filipac/runlet/issues/24).
- In-app updates: [#233](https://github.com/filipac/runlet/issues/233) (Sparkle, the appcast, the install watchdog) and [#252](https://github.com/filipac/runlet/issues/252); the macOS 15 floor for updates: [#248](https://github.com/filipac/runlet/issues/248). How releases are signed and published: [Releasing](releasing.md).
- Runlet's own PHP is described in [compatibility.md](compatibility.md) (its build, extensions, and location).
- The `runlet` command's install rules: [cli.md](cli.md) and `CommandLineInstall.swift` in RunletCore.
