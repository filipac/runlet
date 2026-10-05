# Reading a Runlet crash log

Stable releases leave the debugging symbols out of the app, to keep it small ([#253](https://github.com/filipac/runlet/issues/253)). In a crash report, Runlet's own frames then show as addresses. Each release publishes those symbols as `Runlet-<version>-dSYMs.zip` ([#258](https://github.com/filipac/runlet/issues/258)), so a report can be turned back into function names, files, and lines. Betas keep their symbols in the app and need nothing extra.

## The quick way

In Terminal, on the Mac where Runlet crashed:

```bash
curl -fsSL https://raw.githubusercontent.com/filipac/runlet/main/scripts/symbolicate-crash.sh | sh
```

It takes the newest Runlet crash report in `~/Library/Logs/DiagnosticReports` and prints the crashed thread with names, files, and lines. To read a specific report, or every thread:

```bash
curl -fsSL https://raw.githubusercontent.com/filipac/runlet/main/scripts/symbolicate-crash.sh | sh -s -- --all ~/Library/Logs/DiagnosticReports/Runlet-2026-10-05-120000.ips
```

The script ([scripts/symbolicate-crash.sh](../scripts/symbolicate-crash.sh)) only reads the report and prints:
1. It downloads `Runlet-<version>-dSYMs.zip` from that version's release once and checks it against the release's `SHA256SUMS.txt`.
2. It keeps it in `~/Library/Caches/Runlet-dSYMs`.
3. It refuses symbols whose UUIDs aren't the crashed build's.
4. It runs `atos` on Runlet's own frames. Frames the report already names, such as system code and betas, stay as they are.

It needs Xcode's command line tools (`xcode-select --install`). To read it before running it, download it first:

```bash
curl -fsSLO https://raw.githubusercontent.com/filipac/runlet/main/scripts/symbolicate-crash.sh
```

Then run `sh symbolicate-crash.sh`. The steps below do the same by hand.

## 1. Get the matching symbols

1. Download `Runlet-<version>-dSYMs.zip` from the [release](https://github.com/filipac/runlet/releases) of the Runlet that crashed, and unzip it. It has:
   - `Runlet.app.dSYM`, for the app;
   - `runlet.dSYM`, for the `runlet` command.
2. Check that the symbols belong to that build. These two commands must print the same UUIDs, one per architecture:

   ```bash
   dwarfdump --uuid /Applications/Runlet.app/Contents/MacOS/Runlet
   ```

   ```bash
   dwarfdump --uuid ~/Downloads/Runlet-0.4.2-dSYMs/Runlet.app.dSYM
   ```

   A crash report lists the same UUID next to `Runlet` under **Binary Images**.

## 2. Symbolicate

Crash reports are in `~/Library/Logs/DiagnosticReports/` as `Runlet-<date>.ips`. In Console, they're under **Crash Reports**.

**One address**, with `atos`. Replace the values in angle brackets with ones from the report:

- `-arch` is the report's architecture: `arm64` on Apple silicon, `x86_64` on Intel.
- `-l` is the load address: the start address on the `Runlet` line under **Binary Images**.
- After it come the addresses from the crashed thread's frames.

```bash
atos -o ~/Downloads/Runlet-0.4.2-dSYMs/Runlet.app.dSYM/Contents/Resources/DWARF/Runlet -arch arm64 -l <load address> <address> <address>
```

It prints one line per address: the function, and its file and line when the symbols have them.

**A whole report**, with LLDB:

1. Unzip the dSYMs into a folder Spotlight indexes, such as `~/Downloads`.
2. In Terminal, run `xcrun lldb`, then `crashlog ~/Library/Logs/DiagnosticReports/Runlet-….ips`.

LLDB finds the dSYMs by their UUID.

For the `runlet` command, use `runlet.dSYM/Contents/Resources/DWARF/runlet` and the `runlet` line under **Binary Images**.

## Reporting a crash

Attach the `.ips` file, or the symbolicated frames, to a [GitHub issue](https://github.com/filipac/runlet/issues), with the Runlet version (Runlet ▸ About Runlet) and the macOS version. A crash report can contain paths from your Mac, such as your user folder, and the text of the error that stopped the app, so look it over before you post it.
