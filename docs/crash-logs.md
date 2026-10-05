# Reading a Crash Log

When Runlet crashes, macOS saves a crash report. To keep the app small, stable releases leave their debugging symbols out, so Runlet's own lines in that report show as bare addresses. One command turns them back into function names, files, and lines, which makes a crash report useful in an issue.

Betas keep their symbols in the app, so their reports are readable as they are.

## Symbolicating a Crash Report

In Terminal, on the Mac where Runlet crashed:

```sh
curl -fsSL https://raw.githubusercontent.com/filipac/runlet/main/scripts/symbolicate-crash.sh | sh
```

It reads the newest Runlet crash report and prints the crashed thread with names, files, and lines. To read a specific report, or every thread, add `--all` and the report's path:

```sh
curl -fsSL https://raw.githubusercontent.com/filipac/runlet/main/scripts/symbolicate-crash.sh | sh -s -- --all ~/Library/Logs/DiagnosticReports/Runlet-2026-10-05-120000.ips
```

The script only reads the report and prints. It downloads the symbols for that version of Runlet from its GitHub release once, checks them against the release's checksums, and refuses symbols that don't belong to the build that crashed.

It needs Xcode's command line tools:

```sh
xcode-select --install
```

> [!TIP]
> To read the script before you run it, download it first with `curl -fsSLO https://raw.githubusercontent.com/filipac/runlet/main/scripts/symbolicate-crash.sh`, then run `sh symbolicate-crash.sh`.

## Finding Crash Reports

Crash reports are in `~/Library/Logs/DiagnosticReports/`, named `Runlet-<date>.ips`. In the Console app, they're under **Crash Reports**.

## Reporting a Crash

[Open an issue on GitHub](https://github.com/filipac/runlet/issues) and attach the `.ips` file or the symbolicated lines, with:

- the Runlet version (**Runlet ▸ About Runlet**);
- your macOS version;
- what you were doing when it crashed.

> [!WARNING]
> A crash report can contain paths from your Mac, such as your user folder, and the text of the error that stopped the app. Look it over before you post it.

## For developers

Stable releases strip debugging symbols from the app ([#253](https://github.com/filipac/runlet/issues/253)), and each release publishes them as `Runlet-<version>-dSYMs.zip` ([#258](https://github.com/filipac/runlet/issues/258)).

### What the Script Does

[`scripts/symbolicate-crash.sh`](../scripts/symbolicate-crash.sh) takes the newest Runlet report in `~/Library/Logs/DiagnosticReports` unless it's given one, and:

1. downloads `Runlet-<version>-dSYMs.zip` from that version's release once, and checks it against the release's `SHA256SUMS.txt`;
2. keeps it in `~/Library/Caches/Runlet-dSYMs`;
3. refuses symbols whose UUIDs aren't the crashed build's;
4. runs `atos` on Runlet's own frames. Frames the report already names, such as system code and betas, stay as they are.

### Symbolicating by Hand

**Get the matching symbols.** Download `Runlet-<version>-dSYMs.zip` from the [release](https://github.com/filipac/runlet/releases) of the Runlet that crashed, and unzip it. It has `Runlet.app.dSYM`, for the app, and `runlet.dSYM`, for the `runlet` command.

Check that the symbols belong to that build. These two commands must print the same UUIDs, one per architecture:

```sh
dwarfdump --uuid /Applications/Runlet.app/Contents/MacOS/Runlet
```

```sh
dwarfdump --uuid ~/Downloads/Runlet-0.4.2-dSYMs/Runlet.app.dSYM
```

A crash report lists the same UUID next to `Runlet` under **Binary Images**.

**One address, with `atos`.** Replace the values in angle brackets with ones from the report:

- `-arch` is the report's architecture: `arm64` on Apple silicon, `x86_64` on Intel.
- `-l` is the load address: the start address on the `Runlet` line under **Binary Images**.
- After it come the addresses from the crashed thread's frames.

```sh
atos -o ~/Downloads/Runlet-0.4.2-dSYMs/Runlet.app.dSYM/Contents/Resources/DWARF/Runlet -arch arm64 -l <load address> <address> <address>
```

It prints one line per address: the function, and its file and line when the symbols have them.

**A whole report, with LLDB:**

1. Unzip the dSYMs into a folder Spotlight indexes, such as `~/Downloads`.
2. In Terminal, run `xcrun lldb`, then `crashlog ~/Library/Logs/DiagnosticReports/Runlet-….ips`.

LLDB finds the dSYMs by their UUID.

For the `runlet` command, use `runlet.dSYM/Contents/Resources/DWARF/runlet` and the `runlet` line under **Binary Images**.

How releases build and publish the dSYMs: [Releasing](releasing.md).
